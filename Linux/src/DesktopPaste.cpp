#include "DesktopPaste.h"
#include "TranscriptValidation.h"

#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QUuid>
#include <array>
#include <utility>

namespace sotto {
namespace {
const QString service = QStringLiteral("org.freedesktop.portal.Desktop");
const QString root = QStringLiteral("/org/freedesktop/portal/desktop");
const QString interface = QStringLiteral("org.freedesktop.portal.RemoteDesktop");
const QString requestInterface = QStringLiteral("org.freedesktop.portal.Request");
const QString sessionInterface = QStringLiteral("org.freedesktop.portal.Session");
QString token() { return "cotto_" + QUuid::createUuid().toString(QUuid::Id128); }
// XKB keysyms: Ctrl+Shift+V works as terminal paste and plain-text paste in
// browsers/Obsidian. Never synthesize text, Return, or an arbitrary shortcut.
constexpr int control = 0xffe3, shift = 0xffe1, v = 0x76;
constexpr std::array<std::pair<int, uint>, 6> chord{{{control, 1}, {shift, 1}, {v, 1}, {v, 0}, {shift, 0}, {control, 0}}};
void closeHandle(const QDBusConnection &bus, const QString &path, const QString &type) {
    if (path.isEmpty()) return;
    auto call = QDBusMessage::createMethodCall(service, path, type, "Close");
    call.setAutoStartService(false); bus.asyncCall(call);
}
}
DesktopPaste::DesktopPaste(QObject *parent, QString copyProgram, QString readProgram)
    : QObject(parent), m_bus(QDBusConnection::connectToBus(QDBusConnection::SessionBus, token())),
      m_watcher(service, m_bus, QDBusServiceWatcher::WatchForUnregistration, this),
      m_copyProgram(std::move(copyProgram)), m_readProgram(std::move(readProgram)) {
    m_timeout.setSingleShot(true); m_delay.setSingleShot(true); m_delay.setInterval(75);
    m_clipboardTimeout.setSingleShot(true);
    connect(&m_timeout, &QTimer::timeout, this, [this] { fail("Keyboard permission setup timed out. Paste stays off."); });
    connect(&m_watcher, &QDBusServiceWatcher::serviceUnregistered, this, [this] { m_registered = false; fail("Desktop portal stopped. Enable paste again explicitly."); });
    connect(&m_clipboardTimeout, &QTimer::timeout, this, [this] {
        releaseKeys(); finish("Clipboard staging timed out. Check the destination before using Copy; nothing was retried.");
    });
    connect(&m_writer, &QProcess::started, this, [this] {
        if (!m_pasting) { m_writer.kill(); return; }
        m_writer.write(m_text); m_writer.closeWriteChannel(); m_delay.start();
    });
    connect(&m_writer, &QProcess::finished, this, [this] {
        if (m_pasting) { releaseKeys(); finish("Clipboard ownership ended. Check the destination before using Copy; nothing was retried."); }
    });
    connect(&m_writer, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (m_pasting && error == QProcess::FailedToStart) finish("Cannot start wl-copy. Install wl-clipboard or use Copy.");
    });
    connect(&m_delay, &QTimer::timeout, this, [this] { if (m_pasting) verifyClipboard(0); });
    connect(&m_reader, &QProcess::readyReadStandardOutput, this, [this] {
        if (!m_pasting) return;
        m_readback += m_reader.read(65537 - m_readback.size());
        if (m_readback.size() > 65536) { releaseKeys(); finish("Clipboard content changed. Check the destination before using Copy."); }
    });
    connect(&m_reader, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) {
        if (!m_pasting) return;
        m_clipboardTimeout.stop();
        if (status != QProcess::NormalExit || code != 0 || m_readback != m_text || m_writer.state() != QProcess::Running) {
            releaseKeys(); finish("Clipboard could not be verified. Check the destination before using Copy; nothing was retried."); return;
        }
        sendKey(m_verifiedStep);
    });
    connect(&m_reader, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (m_pasting && error == QProcess::FailedToStart) { releaseKeys(); finish("Cannot start wl-paste. Install wl-clipboard or use Copy."); }
    });
}
DesktopPaste::~DesktopPaste() {
    close(); m_writer.kill(); m_writer.waitForFinished(1000);
    QDBusConnection::disconnectFromBus(m_bus.name());
}

void DesktopPaste::setup() {
    if (busy() || m_ready) return;
    m_setup = true; ++m_epoch; m_status = "Requesting keyboard-only paste permission from KDE…"; emit changed();
    if (m_registered) { createSession(); return; }
    auto call = QDBusMessage::createMethodCall(service, root, "org.freedesktop.host.portal.Registry", "Register");
    call.setArguments({QStringLiteral("org.sotto.Sotto.Dev"), QVariantMap{}});
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(call, 3000), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, watcher, epoch = m_epoch] {
        QDBusPendingReply<> reply = *watcher; watcher->deleteLater();
        if (epoch != m_epoch) return;
        if (reply.isError()) { fail("Could not register cotto for keyboard permission."); return; }
        m_registered = true; createSession();
    });
}
void DesktopPaste::createSession() {
        const auto sessionToken = token();
        const auto expected = root + "/session/" + m_bus.baseService().mid(1).replace('.', '_') + '/' + sessionToken;
        request("CreateSession", {}, {{"session_handle_token", sessionToken}}, [this, expected](const QVariantMap &results) {
            if (results.value("session_handle").toString() != expected) { fail("Invalid keyboard permission session."); return; }
            m_session = expected;
            if (!m_bus.connect(service, m_session, sessionInterface, "Closed", this, SLOT(sessionClosed(QVariantMap,QDBusMessage)))) {
                fail("Could not monitor keyboard permission."); return;
            }
            request("SelectDevices", {QVariant::fromValue(QDBusObjectPath(m_session))}, {{"types", uint(1)}}, [this](const QVariantMap &) {
                request("Start", {QVariant::fromValue(QDBusObjectPath(m_session)), QString{}}, {}, [this](const QVariantMap &granted) {
                    if (granted.value("devices").toUInt() != 1) { fail("Keyboard-only permission was not granted."); return; }
                    m_setup = false; m_ready = true;
                    m_status = "Paste enabled: Ctrl+Shift+V to the focused app. No automatic submission.";
                    emit changed();
                });
            });
        });
}
void DesktopPaste::request(const QString &method, QVariantList arguments, QVariantMap options,
                           std::function<void(const QVariantMap &)> result) {
    const auto handle = token();
    m_request = root + "/request/" + m_bus.baseService().mid(1).replace('.', '_') + '/' + handle;
    m_result = std::move(result); options.insert("handle_token", handle);
    if (!m_bus.connect(service, m_request, requestInterface, "Response", this, SLOT(response(uint,QVariantMap,QDBusMessage)))) {
        fail("Could not monitor the keyboard permission request."); return;
    }
    arguments.append(options);
    auto call = QDBusMessage::createMethodCall(service, root, interface, method); call.setArguments(arguments);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(call, 3000), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, watcher, epoch = m_epoch, path = m_request] {
        QDBusPendingReply<QDBusObjectPath> reply = *watcher; watcher->deleteLater();
        if (epoch != m_epoch || m_request != path) return;
        if (reply.isError() || reply.value().path() != path) fail("Keyboard permission request failed.");
    });
    m_timeout.start(120000);
}
void DesktopPaste::response(uint code, const QVariantMap &results, const QDBusMessage &message) {
    if (m_request.isEmpty() || m_request != message.path()) return;
    auto result = std::move(m_result); clearRequest(false);
    if (code != 0) { fail("Keyboard permission was declined or cancelled. Paste stays off."); return; }
    if (result) result(results);
}
void DesktopPaste::clearRequest(bool cancelRequest) {
    m_timeout.stop(); m_result = {};
    if (!m_request.isEmpty()) {
        m_bus.disconnect(service, m_request, requestInterface, "Response", this, SLOT(response(uint,QVariantMap,QDBusMessage)));
        if (cancelRequest) closeHandle(m_bus, m_request, requestInterface);
        m_request.clear();
    }
}
void DesktopPaste::sessionClosed(const QVariantMap &, const QDBusMessage &message) {
    if (!m_session.isEmpty() && message.path() == m_session) fail("KDE closed keyboard access. Paste stays off until re-enabled.");
}
void DesktopPaste::close() {
    cancel(); ++m_epoch; clearRequest(true);
    if (!m_session.isEmpty()) {
        m_bus.disconnect(service, m_session, sessionInterface, "Closed", this, SLOT(sessionClosed(QVariantMap,QDBusMessage)));
        closeHandle(m_bus, m_session, sessionInterface); m_session.clear();
    }
    m_ready = false; m_setup = false;
}
void DesktopPaste::fail(const QString &message) { close(); m_status = message; emit changed(); }
void DesktopPaste::disconnectPaste() { fail("Automatic paste disabled. Saved transcripts remain available for Copy."); }

void DesktopPaste::paste(const QString &text) {
    if (m_pasting) return; // One take owns delivery; never queue/retry another.
    m_pasting = true; m_dispatched = false; ++m_epoch;
    const auto rejection = transcriptRejection(text);
    if (!m_ready || !rejection.isEmpty()) { finish(rejection.isEmpty() ? "Paste permission is unavailable. Use Copy." : rejection); return; }
    // A foreground wl-copy is our clipboard owner, not an untracked daemon.
    // Its exit means ownership was lost. Keep it alive after successful delivery.
    m_pasting = false;
    if (m_writer.state() != QProcess::NotRunning) { m_writer.kill(); m_writer.waitForFinished(1000); }
    m_pasting = true; m_text = text.toUtf8(); m_readback.clear();
    m_clipboardTimeout.start(2000);
    m_writer.start(m_copyProgram, {"--foreground", "--type", "text/plain;charset=utf-8"});
    emit changed();
}
QDBusMessage DesktopPaste::keyCall(int key, uint state) const {
    auto call = QDBusMessage::createMethodCall(service, root, interface, "NotifyKeyboardKeysym");
    call.setAutoStartService(false);
    call.setArguments({QVariant::fromValue(QDBusObjectPath(m_session)), QVariantMap{}, key, state});
    return call;
}
void DesktopPaste::sendKey(int step) {
    if (!m_pasting || !m_ready) return;
    if (m_writer.state() != QProcess::Running) { cancel(); return; }
    if (step == int(chord.size())) { finish("Paste shortcut sent. Insertion is unconfirmed; check the focused app. Nothing was submitted."); return; }
    m_dispatched = true; // Consume before sending the first event; no retry on errors.
    const auto [key, state] = chord[step];
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(keyCall(key, state), 1000), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, watcher, step, epoch = m_epoch] {
        QDBusPendingReply<> reply = *watcher; watcher->deleteLater();
        if (epoch != m_epoch || !m_pasting) return;
        if (reply.isError()) { fail("Paste outcome unknown. Check the destination before using Copy; paste access is now disabled."); return; }
        // Check again immediately before V, including changes while modifiers
        // were pressed. A mismatch releases our keys and never retries paste.
        if (step == 1) verifyClipboard(2);
        else sendKey(step + 1);
    });
}
void DesktopPaste::verifyClipboard(int step) {
    m_verifiedStep = step; m_readback.clear(); m_clipboardTimeout.start(2000);
    m_reader.start(m_readProgram, {"--no-newline", "--type", "text/plain;charset=utf-8"});
}
void DesktopPaste::releaseKeys() {
    // Best-effort release only our fixed chord, including an unacknowledged key.
    // Closing the session on transport failure also disposes its virtual device.
    if (m_dispatched && !m_session.isEmpty())
        for (int key : {v, shift, control}) m_bus.asyncCall(keyCall(key, 0), 1000);
}
void DesktopPaste::finish(const QString &message) {
    if (!m_pasting) return;
    const auto receipt = m_dispatched ? QStringLiteral("uncertain") : QStringLiteral("blocked");
    m_delay.stop(); m_clipboardTimeout.stop(); m_pasting = false; m_dispatched = false; m_text.clear();
    if (m_reader.state() != QProcess::NotRunning) { m_reader.kill(); m_reader.waitForFinished(1000); }
    emit changed(); emit finished(receipt, message);
}
void DesktopPaste::cancel() {
    if (!m_pasting) return;
    ++m_epoch; releaseKeys();
    finish(m_dispatched ? "Paste cancelled after dispatch began. Check the destination; no retry."
                        : "Paste cancelled before dispatch. Transcript remains available for Copy.");
}
} // namespace sotto
