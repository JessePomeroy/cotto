#pragma once

#include <QJsonObject>
#include <QLocalServer>
#include <QPointer>
#include <QTimer>
#include <QLockFile>
#include <memory>

class QLocalSocket;

namespace sotto {
// Explicit Pi-owned requests, not discovery of the desktop's focused field.
// A connection owns at most one take; losing it never retargets or retries.
class PiDictationBridge : public QObject {
    Q_OBJECT
public:
    explicit PiDictationBridge(QObject *parent = nullptr);
    ~PiDictationBridge() override;
    bool listen(const QString &path);
    QString errorString() const { return m_error; }
    void recording(const QString &id);
    void processing(const QString &id);
    void complete(const QString &id, const QString &text);
    void reject(const QString &id, const QString &message);
signals:
    void startRequested(const QString &id);
    void stopRequested(const QString &id);
    void cancelRequested(const QString &id);
    void receipt(const QString &id, const QString &status);
private:
    enum class Phase { Idle, Starting, Recording, Processing, Receipt };
    void accept();
    void receive();
    void drop();
    void send(const QJsonObject &message);
    void clear();
    bool expired();
    QLocalServer m_server;
    std::unique_ptr<QLockFile> m_lock;
    QPointer<QLocalSocket> m_peer;
    QTimer m_deadline;
    QTimer m_partialDeadline;
    QByteArray m_buffer;
    QString m_take;
    QString m_error;
    // One server-issued ID per connection; consumed before notifying capture.
    QString m_offer;
    Phase m_phase = Phase::Idle;
};
} // namespace sotto
