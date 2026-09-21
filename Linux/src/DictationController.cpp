#include "DictationController.h"

#include <QClipboard>
#include <QGuiApplication>
#include <utility>

namespace sotto {
DictationController::DictationController(CaptureController &capture, QUrl endpoint, DesktopPaste &paste, QObject *parent)
    : QObject(parent), m_capture(capture), m_client(std::move(endpoint), this), m_paste(paste) {
    connect(&m_paste, &DesktopPaste::changed, this, [this] {
        if (m_pasteThisTake && !m_paste.ready()) m_pasteRevoked = true;
    });
    connect(&m_paste, &DesktopPaste::finished, this, [this](const QString &receipt, const QString &message) {
        if (!m_pastePending) return;
        m_pastePending = false; m_deliveryStatus = message;
        m_client.reportDelivery(receipt, message); emit changed();
    });
    connect(&m_client, &GenerationClient::completed, this, [this](const QString &, const QString &text) {
        if (!m_owner.isEmpty()) {
            m_awaitingReceipt = true;
            m_deliveryStatus = QStringLiteral("Transcript ready; waiting for the requesting Pi editor's insertion receipt.");
            emit ownedTranscript(m_owner, text);
            emit changed();
            return;
        }
        // The route was selected before recording, never as a Pi failure fallback.
        if (m_pasteThisTake && m_pasteRevoked) {
            m_deliveryStatus = QStringLiteral("Paste permission changed during this take. Review the transcript and use Copy.");
            m_client.reportDelivery(QStringLiteral("blocked"), m_deliveryStatus);
        } else if (m_pasteThisTake) {
            m_pastePending = true;
            m_deliveryStatus = QStringLiteral("Pasting to the focused app…");
            m_paste.paste(text);
        } else m_deliveryStatus = QStringLiteral("Transcript saved. Use Copy to insert it yourself.");
        emit changed();
    });
    connect(&m_client, &GenerationClient::deliveryReportFailed, this, [this] {
        m_deliveryStatus += QStringLiteral(" The server receipt was not saved.");
        emit changed();
    });
    connect(&m_client, &GenerationClient::changed, this, &DictationController::changed);
    connect(&m_client, &GenerationClient::changed, this, [this] {
        if (!m_client.active()) {
            m_holdOwned = false;
            if (!m_client.completedSuccessfully()) abortOwner(m_client.status());
        }
    });
    connect(&m_client, &GenerationClient::captureRequested, this, [this](bool keepOriginal) {
        if (!m_capture.startDictation()) {
            m_error = m_capture.status();
            m_client.cancel();
            return;
        }
        m_converting = m_converter.configure(m_capture.activeFormat(), m_capture.selectedChannel(), keepOriginal);
        if (!m_converting) {
            m_error = QStringLiteral("The selected audio format cannot be converted for dictation.");
            m_client.cancel();
        } else if (!m_owner.isEmpty()) emit ownedRecording(m_owner);
    });
    connect(&m_client, &GenerationClient::captureMustStop, this, [this] {
        m_paste.cancel();
        abortOwner(QStringLiteral("Pi dictation stopped or failed. No late insertion will be requested."));
        m_converting = false;
        if (m_capture.recording() && !m_capture.testing()) m_capture.stopTest();
    });
    connect(&m_capture, &CaptureController::samplesReady, this, [this](const QByteArray &bytes) {
        if (!m_converting) return;
        const auto converted = m_converter.consume(bytes);
        if (!converted.error.isEmpty()) {
            m_error = converted.error;
            m_client.cancel();
            return;
        }
        const auto format = m_capture.activeFormat();
        m_client.append(converted.inference, converted.original, format.sampleRate(), format.channelCount());
    });
    connect(&m_capture, &CaptureController::captureEnded, this, [this](bool failed) {
        if (!m_converting) return;
        m_converting = false;
        if (failed) {
            m_error = m_capture.status();
            m_client.cancel();
            return;
        }
        const auto tail = m_converter.finish();
        if (!tail.error.isEmpty()) {
            m_error = tail.error;
            m_client.cancel();
            return;
        }
        const auto format = m_capture.activeFormat();
        m_client.append(tail.inference, tail.original, format.sampleRate(), format.channelCount());
        if (!m_owner.isEmpty()) emit ownedProcessing(m_owner);
        m_client.finish();
    });
}

void DictationController::start() {
    if (active() || m_capture.recording()) return;
    beginRecording();
}

void DictationController::beginRecording(bool paste) {
    m_error.clear();
    m_awaitingReceipt = false;
    m_pasteThisTake = paste; m_pasteRevoked = false;
    m_deliveryStatus = !m_owner.isEmpty()
        ? QStringLiteral("Pi-owned dictation: text returns to the requesting editor, without submission.")
        : paste ? QStringLiteral("Global dictation: release all shortcut keys and keep the destination focused. Paste does not submit.")
                : QStringLiteral("Recording for manual Copy; automatic paste is off.");
    m_client.start();
}

bool DictationController::startOwned(const QString &id) {
    if (id.isEmpty() || active() || m_capture.recording()) return false;
    m_owner = id;
    beginRecording();
    return true;
}

void DictationController::stopOwned(const QString &id) { if (m_owner == id) stop(); }
void DictationController::cancelOwned(const QString &id) { if (m_owner == id) cancel(); }

void DictationController::abortOwner(const QString &message) {
    if (m_owner.isEmpty()) return;
    const auto id = std::exchange(m_owner, {});
    m_deliveryStatus = m_awaitingReceipt
        ? QStringLiteral("Pi insertion is unconfirmed. Check the draft before copying; no automatic retry.")
        : message;
    if (m_awaitingReceipt) m_client.reportDelivery(QStringLiteral("uncertain"), m_deliveryStatus);
    m_awaitingReceipt = false;
    emit ownedAborted(id, m_deliveryStatus);
    emit changed();
}

void DictationController::deliveryReceipt(const QString &id, const QString &status) {
    if (id != m_owner || !m_awaitingReceipt) return;
    m_owner.clear(); m_awaitingReceipt = false;
    if (status == "inserted") m_deliveryStatus = QStringLiteral("Inserted into the requesting Pi draft. Nothing was submitted.");
    else if (status == "blocked") m_deliveryStatus = QStringLiteral("Pi insertion was blocked. Review the transcript here before copying.");
    else m_deliveryStatus = QStringLiteral("Pi insertion is unconfirmed. Check the draft before copying; no automatic retry.");
    m_client.reportDelivery(status, m_deliveryStatus);
    emit changed();
}

void DictationController::stop() {
    m_holdOwned = false;
    if (m_capture.recording() && !m_capture.testing()) m_capture.stopTest();
    else if (active()) cancel();
}

void DictationController::cancel() {
    m_holdOwned = false;
    m_paste.cancel();
    abortOwner(QStringLiteral("Pi dictation cancelled. No insertion will be requested."));
    m_client.cancel();
}

void DictationController::shortcutPressed(const QString &id) {
    if (id == "cancel") { cancel(); return; }
    if (!m_owner.isEmpty()) return; // The global toggle cannot take over a Pi-owned recording.
    if (id == "hold") {
        if (!active() && !m_capture.recording()) { m_holdOwned = true; beginRecording(m_paste.ready()); }
    } else if (id == "toggle" && !m_holdOwned) {
        if (!active() && !m_capture.recording()) beginRecording(m_paste.ready());
        else if (m_client.canStopRecording()) stop();
    }
}

void DictationController::shortcutReleased(const QString &id) {
    if (id == "hold" && std::exchange(m_holdOwned, false)) stop();
}

void DictationController::copyTranscript() {
    if (!m_client.transcript().isEmpty()) QGuiApplication::clipboard()->setText(m_client.transcript());
}
} // namespace sotto
