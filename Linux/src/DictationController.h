#pragma once

#include "AudioConverter.h"
#include "CaptureController.h"
#include "GenerationClient.h"
#include "DesktopPaste.h"

namespace sotto {
class DictationController : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool active READ active NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
    Q_PROPERTY(QString transcript READ transcript NOTIFY changed)
    Q_PROPERTY(QString deliveryStatus READ deliveryStatus NOTIFY changed)
public:
    DictationController(CaptureController &capture, QUrl endpoint, DesktopPaste &paste, QObject *parent = nullptr);
    bool active() const { return m_client.active() || !m_owner.isEmpty() || m_pastePending; }
    QString status() const { return m_error.isEmpty() ? m_client.status() : m_error; }
    QString transcript() const { return m_client.transcript(); }
    QString deliveryStatus() const { return m_deliveryStatus; }
    Q_INVOKABLE void start();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void copyTranscript();
    void shortcutPressed(const QString &id);
    void shortcutReleased(const QString &id);
    bool startOwned(const QString &id);
    void stopOwned(const QString &id);
    void cancelOwned(const QString &id);
    void deliveryReceipt(const QString &id, const QString &status);
signals:
    void changed();
    void ownedRecording(const QString &id);
    void ownedProcessing(const QString &id);
    void ownedTranscript(const QString &id, const QString &text);
    void ownedAborted(const QString &id, const QString &message);
private:
    void beginRecording(bool paste = false);
    void abortOwner(const QString &message);
    CaptureController &m_capture;
    GenerationClient m_client;
    AudioConverter m_converter;
    DesktopPaste &m_paste;
    bool m_pasteThisTake = false, m_pastePending = false, m_pasteRevoked = false;
    QString m_deliveryStatus = QStringLiteral("Manual recordings stay here for Copy. Pi dictation returns to its requesting editor.");
    bool m_converting = false;
    bool m_holdOwned = false;
    QString m_error;
    QString m_owner;
    bool m_awaitingReceipt = false;
};
} // namespace sotto
