#include "PiDictationBridge.h"
#include "TranscriptValidation.h"

#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QUuid>
#include <QScopeGuard>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

namespace sotto {
namespace {
bool privateDirectory(const QString &path) {
    struct stat info {};
    const auto bytes = QFile::encodeName(path);
    return ::lstat(bytes.constData(), &info) == 0 && S_ISDIR(info.st_mode)
        && info.st_uid == ::getuid() && (info.st_mode & 0077) == 0;
}
QString requestId(const QJsonObject &message) {
    const auto value = message.value("id").toString();
    const QUuid id(value);
    return value.size() == 36 && !id.isNull()
        && id.toString(QUuid::WithoutBraces).compare(value, Qt::CaseInsensitive) == 0
        ? value.toLower() : QString();
}
}

PiDictationBridge::PiDictationBridge(QObject *parent) : QObject(parent) {
    m_deadline.setSingleShot(true);
    m_partialDeadline.setSingleShot(true);
    connect(&m_server, &QLocalServer::newConnection, this, &PiDictationBridge::accept);
    connect(&m_partialDeadline, &QTimer::timeout, this, &PiDictationBridge::drop);
    connect(&m_deadline, &QTimer::timeout, this, &PiDictationBridge::drop);
}
PiDictationBridge::~PiDictationBridge() { drop(); m_server.close(); }

bool PiDictationBridge::listen(const QString &path) {
    const QFileInfo file(path);
    if (m_server.isListening() || !file.isAbsolute() || !privateDirectory(file.absolutePath())
        || QFile::encodeName(path).size() > 103) {
        m_error = QStringLiteral("Pi dictation needs a short socket path inside a private, user-owned directory.");
        return false;
    }
    m_lock = std::make_unique<QLockFile>(path + ".lock");
    m_lock->setStaleLockTime(0); // PID liveness, never the age of a healthy instance.
    auto unlockOnFailure = qScopeGuard([this] { if (!m_server.isListening()) m_lock.reset(); });
    if (!m_lock->tryLock(0)) {
        m_error = QStringLiteral("Another cotto instance owns the Pi socket."); return false;
    }
    const auto bytes = QFile::encodeName(path);
    struct stat before {}, after {};
    if (::lstat(bytes.constData(), &before) == 0) {
        if (!S_ISSOCK(before.st_mode) || before.st_uid != ::getuid()) {
            m_error = QStringLiteral("Existing Pi endpoint is not an owned socket; it was preserved."); return false;
        }
        QLocalSocket probe; probe.connectToServer(path);
        if (probe.waitForConnected(100) || probe.error() != QLocalSocket::ConnectionRefusedError) {
            m_error = QStringLiteral("The existing Pi endpoint may still be active; it was preserved."); return false;
        }
        // Serialize cooperating instances and remove only the refused, unchanged
        // socket. Regular files, symlinks and live legacy listeners are untouched.
        if (::lstat(bytes.constData(), &after) != 0 || after.st_ino != before.st_ino
            || after.st_dev != before.st_dev || ::unlink(bytes.constData()) != 0) {
            m_error = QStringLiteral("The stale Pi endpoint changed or could not be removed."); return false;
        }
    }
    // Qt's explicit access options bind a temporary socket then rename it,
    // which can overwrite an existing path. Default bind fails atomically if
    // the endpoint exists. The private parent protects it until chmod below.
    m_server.setSocketOptions(QLocalServer::NoOptions);
    if (!m_server.listen(path)) {
        m_error = QStringLiteral("Cannot open the Pi dictation socket. Another instance or a stale endpoint may exist.");
        return false;
    }
    if (!QFile::setPermissions(path, QFile::ReadOwner | QFile::WriteOwner)) {
        m_server.close();
        m_error = QStringLiteral("Cannot restrict the Pi dictation socket permissions.");
        return false;
    }
    return true;
}

void PiDictationBridge::accept() {
    while (m_server.hasPendingConnections()) {
        auto *peer = m_server.nextPendingConnection();
        struct ucred credentials {};
        socklen_t size = sizeof(credentials);
        const bool owned = ::getsockopt(static_cast<int>(peer->socketDescriptor()), SOL_SOCKET,
            SO_PEERCRED, &credentials, &size) == 0 && credentials.uid == ::getuid();
        if (m_peer || !owned) { peer->abort(); peer->deleteLater(); continue; }
        m_peer = peer;
        peer->setReadBufferSize(4097);
        connect(peer, &QLocalSocket::readyRead, this, &PiDictationBridge::receive);
        connect(peer, &QLocalSocket::disconnected, this, [this, peer] { if (m_peer == peer) drop(); });
        connect(peer, &QLocalSocket::errorOccurred, this, [this, peer] { if (m_peer == peer) drop(); });
        m_deadline.start(300000);
        m_offer = QUuid::createUuid().toString(QUuid::WithoutBraces);
        send({{"v", 2}, {"event", "hello"}, {"mode", "pi-owned"}, {"id", m_offer}});
    }
}

void PiDictationBridge::send(const QJsonObject &message) {
    if (!m_peer) return;
    if (m_peer->bytesToWrite() > 256 * 1024) { drop(); return; }
    m_peer->write(QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n');
}

void PiDictationBridge::clear() {
    m_take.clear(); m_phase = Phase::Idle;
    m_deadline.start(300000);
}

void PiDictationBridge::drop() {
    auto peer = m_peer;
    m_peer.clear();
    const auto take = m_take;
    const bool uncertain = m_phase == Phase::Receipt;
    clear(); m_offer.clear(); m_deadline.stop(); m_partialDeadline.stop(); m_buffer.clear();
    if (peer) { peer->disconnect(this); peer->abort(); peer->deleteLater(); }
    if (!take.isEmpty()) {
        if (uncertain) emit receipt(take, QStringLiteral("uncertain"));
        else emit cancelRequested(take);
    }
}

bool PiDictationBridge::expired() {
    if (!m_deadline.isActive() || m_deadline.remainingTime() > 0) return false;
    drop();
    return true;
}

void PiDictationBridge::receive() {
    if (!m_peer || expired()) return;
    if (m_partialDeadline.isActive() && m_partialDeadline.remainingTime() == 0) { drop(); return; }
    m_buffer += m_peer->readAll();
    if (m_buffer.size() > 4096) { drop(); return; }
    int frames = 0;
    while (m_peer && m_buffer.contains('\n')) {
        if (++frames > 16) { drop(); return; }
        const auto newline = m_buffer.indexOf('\n');
        const auto line = m_buffer.left(newline);
        m_buffer.remove(0, newline + 1);
        m_partialDeadline.stop();
        QJsonParseError error;
        const auto document = QJsonDocument::fromJson(line, &error);
        const auto message = document.object();
        const auto id = requestId(message);
        const auto op = message.value("op").toString();
        if (error.error != QJsonParseError::NoError || !document.isObject() || id.isEmpty()
            || message.value("v").toDouble() != 2 || message.size() != (op == "receipt" ? 4 : 3)) {
            drop(); return;
        }
        if (op == "start") {
            if (m_phase != Phase::Idle || id != m_offer) {
                send({{"v", 2}, {"id", id}, {"event", "error"}, {"message", "Busy or invalid take. Reconnect for a fresh take."}});
                continue;
            }
            // Pi already opens one connection per take. Never reissue an ID on
            // this connection, including after rejection, cancellation or receipt.
            m_offer.clear(); m_take = id; m_phase = Phase::Starting;
            m_deadline.start(15000);
            emit startRequested(id);
        } else if (op == "cancel" && id == m_take) {
            const bool uncertain = m_phase == Phase::Receipt;
            clear();
            send({{"v", 2}, {"id", id}, {"event", "cancelled"}});
            if (uncertain) emit receipt(id, QStringLiteral("uncertain"));
            else emit cancelRequested(id);
        } else if (op == "stop" && id == m_take && m_phase == Phase::Recording) {
            processing(id);
            emit stopRequested(id);
        } else if (op == "receipt" && id == m_take && m_phase == Phase::Receipt) {
            const auto status = message.value("status").toString();
            if (status != "inserted" && status != "blocked" && status != "uncertain") { drop(); return; }
            clear();
            emit receipt(id, status);
        } else { drop(); return; }
    }
    if (!m_buffer.isEmpty() && !m_partialDeadline.isActive()) m_partialDeadline.start(5000);
}

void PiDictationBridge::recording(const QString &id) {
    if (id != m_take || m_phase != Phase::Starting || expired()) return;
    m_phase = Phase::Recording; m_deadline.start(240000);
    send({{"v", 2}, {"id", id}, {"event", "recording"}});
}

void PiDictationBridge::processing(const QString &id) {
    if (id != m_take || m_phase != Phase::Recording || expired()) return;
    m_phase = Phase::Processing; m_deadline.start(120000);
    send({{"v", 2}, {"id", id}, {"event", "processing"}});
}

void PiDictationBridge::complete(const QString &id, const QString &text) {
    if (id != m_take || (m_phase != Phase::Processing && m_phase != Phase::Recording) || expired()) return;
    if (!transcriptRejection(text).isEmpty()) {
        clear();
        send({{"v", 2}, {"id", id}, {"event", "error"},
              {"message", "Transcript cannot be safely inserted. Review it in cotto."}});
        emit receipt(id, QStringLiteral("blocked"));
        return;
    }
    m_phase = Phase::Receipt; m_deadline.start(5000);
    send({{"v", 2}, {"id", id}, {"event", "transcript"}, {"text", text}});
}

void PiDictationBridge::reject(const QString &id, const QString &message) {
    if (id != m_take) return;
    const bool uncertain = m_phase == Phase::Receipt;
    clear();
    send({{"v", 2}, {"id", id}, {"event", "error"}, {"message", message.left(300)}});
    emit receipt(id, uncertain ? QStringLiteral("uncertain") : QStringLiteral("blocked"));
    emit cancelRequested(id);
}
} // namespace sotto
