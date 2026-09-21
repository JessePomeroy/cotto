#pragma once
#include <QLockFile>
#include <QObject>
#include <QTimer>
#include <memory>

namespace sotto {
// A read-only, short-lived recording signal for same-user UI observers.
// Contains no transcript, device identity, or control capability.
class RecordingStatus : public QObject {
    Q_OBJECT
public:
    explicit RecordingStatus(QObject *parent = nullptr);
    bool open(const QString &directory);
    void setRecording(bool recording);
private:
    void publish();
    QString m_path;
    bool m_recording = false;
    QTimer m_heartbeat;
    std::unique_ptr<QLockFile> m_lock;
};
}
