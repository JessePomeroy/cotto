#pragma once

#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QPointer>
#include <QQueue>
#include <QSettings>
#include <QUrl>
#include <functional>

class QNetworkReply;

namespace sotto {
class GenerationClient : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool active READ active NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
    Q_PROPERTY(QString transcript READ transcript NOTIFY changed)
public:
    explicit GenerationClient(QUrl endpoint, QObject *parent = nullptr);
    bool active() const;
    bool canStopRecording() const;
    bool completedSuccessfully() const;
    void reportDelivery(const QString &status, const QString &message);
    QString status() const { return m_status; }
    QString transcript() const { return m_transcript; }
    void start();
    void append(const QByteArray &inference, const QByteArray &original, int originalRate, int originalChannels);
    void finish();
    void cancel();
signals:
    void changed();
    void captureRequested(bool keepOriginal);
    void captureMustStop();
    void completed(const QString &id, const QString &insertionText);
    void deliveryReportFailed();
private:
    enum class State { Idle, Admitting, Recording, Uploading, Processing, Cancelling, Completed, Cancelled, Failed };
    struct Chunk {
        QString kind;
        QByteArray data;
        int rate;
        int channels;
        int sequence;
        qint64 frames;
    };
    using Callback = std::function<void(const QJsonObject &, const QString &)>;
    void request(const QString &path, const QByteArray &body, const QByteArray &contentType, Callback callback);
    void enqueue(const QString &kind, const QByteArray &data, int rate, int channels);
    void buffer(const QString &kind, const QByteArray &data, int rate, int channels);
    void pump();
    void finishUpload();
    void watch();
    void receiveRecord(const QJsonObject &record);
    void cancelRemote();
    void fail(const QString &message);
    void setState(State state, const QString &status);
    QUrl m_endpoint;
    QNetworkAccessManager m_network;
    QSettings m_settings;
    QPointer<QNetworkReply> m_events;
    QByteArray m_eventBuffer;
    QQueue<Chunk> m_queue;
    QByteArray m_pendingInference;
    QByteArray m_pendingOriginal;
    int m_originalRate = 0;
    int m_originalChannels = 0;
    qint64 m_queuedBytes = 0;
    quint64 m_epoch = 0;
    State m_state = State::Idle;
    QString m_id;
    QString m_requestId;
    QString m_status = QStringLiteral("Ready to connect.");
    QString m_transcript;
    bool m_keepOriginal = false;
    bool m_sending = false;
    int m_inferenceSequence = 0;
    int m_originalSequence = 0;
    qint64 m_inferenceFrames = 0;
    qint64 m_originalFrames = 0;
};
} // namespace sotto
