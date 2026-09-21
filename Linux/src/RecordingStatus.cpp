#include "RecordingStatus.h"
#include <QDateTime>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <sys/stat.h>
#include <unistd.h>

namespace sotto {
RecordingStatus::RecordingStatus(QObject *parent) : QObject(parent) {
    m_heartbeat.setInterval(1000);
    connect(&m_heartbeat, &QTimer::timeout, this, &RecordingStatus::publish);
}
bool RecordingStatus::open(const QString &directory) {
    if (!m_path.isEmpty()) return false;
    const auto path = QFile::encodeName(directory);
    ::mkdir(path.constData(), 0700);
    struct stat info {};
    if (::lstat(path.constData(), &info) != 0 || !S_ISDIR(info.st_mode)
        || info.st_uid != ::getuid() || (info.st_mode & 0077)) return false;
    auto lock = std::make_unique<QLockFile>(directory + "/publisher.lock");
    lock->setStaleLockTime(0);
    if (!lock->tryLock(0)) return false;
    m_lock = std::move(lock);
    m_path = directory + "/recording.json";
    publish();
    return true;
}
void RecordingStatus::setRecording(bool recording) {
    m_recording = recording;
    if (recording) m_heartbeat.start(); else m_heartbeat.stop();
    publish();
}
void RecordingStatus::publish() {
    if (m_path.isEmpty()) return;
    // Atomic replacement plus expiry prevents a crashed process leaving a lit
    // recording indicator. Failure expires the previous signal; never guess.
    QSaveFile file(m_path);
    const auto bytes = QJsonDocument(QJsonObject{{"v", 1}, {"recording", m_recording},
        {"updatedAt", QDateTime::currentMSecsSinceEpoch()}}).toJson(QJsonDocument::Compact);
    if (!file.open(QIODevice::WriteOnly) || !file.setPermissions(QFile::ReadOwner | QFile::WriteOwner)
        || file.write(bytes) != bytes.size()) return;
    file.commit();
}
}
