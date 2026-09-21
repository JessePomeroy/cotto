#include "GenerationClient.h"
#include "PersonalDictionary.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSysInfo>
#include <QUuid>

namespace sotto {
namespace {
constexpr qsizetype maximumRecordBytes = 1024 * 1024;
QString uuid() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
QByteArray json(const QJsonObject &object) { return QJsonDocument(object).toJson(QJsonDocument::Compact); }
bool loopback(const QUrl &url) {
    return url.scheme() == "http" && (url.host() == "127.0.0.1" || url.host() == "localhost" || url.host() == "::1")
        && url.userInfo().isEmpty() && !url.hasQuery() && !url.hasFragment();
}
}

GenerationClient::GenerationClient(QUrl endpoint, QObject *parent)
    : QObject(parent), m_endpoint(std::move(endpoint)), m_network(this) {}

bool GenerationClient::active() const {
    return m_state == State::Admitting || m_state == State::Recording || m_state == State::Uploading
        || m_state == State::Processing || m_state == State::Cancelling;
}

bool GenerationClient::canStopRecording() const { return m_state == State::Admitting || m_state == State::Recording; }

bool GenerationClient::completedSuccessfully() const { return m_state == State::Completed; }

void GenerationClient::reportDelivery(const QString &status, const QString &message) {
    if (!completedSuccessfully() || m_id.isEmpty()
        || (status != "inserted" && status != "blocked" && status != "uncertain")) return;
    // Pi's receiver vocabulary differs from the existing server API.
    const auto serverStatus = status == "blocked" ? QStringLiteral("failed")
        : status == "uncertain" ? QStringLiteral("unconfirmed") : status;
    const auto body = json({{"status", serverStatus}, {"message", message},
        {"reportedAt", QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)}});
    request(QString("/v1/generations/%1/delivery").arg(m_id), body, "application/json",
        [this](const QJsonObject &, const QString &error) { if (!error.isEmpty()) emit deliveryReportFailed(); });
}

void GenerationClient::setState(State state, const QString &status) {
    m_state = state;
    m_status = status;
    emit changed();
}

void GenerationClient::request(const QString &path, const QByteArray &body, const QByteArray &contentType, Callback callback) {
    auto url = m_endpoint;
    url.setPath(path.section('?', 0, 0));
    if (path.contains('?')) url.setQuery(path.section('?', 1));
    QNetworkRequest request(url);
    request.setTransferTimeout(10000);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    request.setHeader(QNetworkRequest::ContentTypeHeader, contentType);
    auto *reply = m_network.post(request, body);
    reply->setReadBufferSize(maximumRecordBytes + 1);
    const auto epoch = m_epoch;
    connect(reply, &QNetworkReply::readyRead, this, [reply] {
        if (reply->bytesAvailable() > maximumRecordBytes) reply->abort();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, epoch, callback = std::move(callback)] {
        const auto body = reply->read(maximumRecordBytes + 1);
        const auto document = QJsonDocument::fromJson(body);
        const auto httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        QString error;
        if (reply->error() != QNetworkReply::NoError || httpStatus < 200 || httpStatus >= 300) {
            error = document.object().value("message").toString().left(500);
            if (error.isEmpty()) error = QStringLiteral("The local inference request failed. No insertion was attempted.");
        } else if (body.size() > maximumRecordBytes || !document.isObject()) {
            error = QStringLiteral("The server returned invalid or oversized data.");
        }
        reply->deleteLater();
        if (epoch == m_epoch) callback(document.object(), error);
    });
}

void GenerationClient::start() {
    if (active()) return;
    if (!loopback(m_endpoint)) { fail(QStringLiteral("Dictation requires a localhost HTTP endpoint.")); return; }
    PersonalDictionary dictionary;
    if (!dictionary.error().isEmpty()) { fail(dictionary.error()); return; }
    ++m_epoch;
    m_id.clear();
    m_requestId = uuid();
    m_queue.clear();
    m_pendingInference.clear();
    m_pendingOriginal.clear();
    m_originalRate = m_originalChannels = 0;
    m_queuedBytes = 0;
    m_sending = false;
    m_inferenceSequence = m_originalSequence = 0;
    m_inferenceFrames = m_originalFrames = 0;
    auto deviceId = m_settings.value("device/id").toString();
    if (deviceId.isEmpty()) {
        deviceId = uuid();
        m_settings.setValue("device/id", deviceId);
    }
    setState(State::Admitting, QStringLiteral("Preparing recording…"));
    request("/v1/generations", json({{"requestID", m_requestId}, {"mode", "dictation"},
        {"personalDictionary", dictionary.snapshot()},
        {"device", QJsonObject{{"id", deviceId}, {"name", QSysInfo::machineHostName()}}}}), "application/json",
        [this](const QJsonObject &record, const QString &error) {
            if (!error.isEmpty()) {
                if (m_state == State::Cancelling) setState(State::Cancelled, QStringLiteral("Recording cancelled before capture started."));
                else fail(error);
                return;
            }
            const auto id = record.value("id").toString();
            const auto keep = record.value("settings").toObject().value("preferences").toObject().value("keepOriginalAudio");
            if (QUuid(id).isNull() || QUuid(record.value("requestID").toString()) != QUuid(m_requestId) || !keep.isBool()) {
                fail(QStringLiteral("The server returned an invalid recording admission."));
                return;
            }
            m_id = id;
            m_keepOriginal = keep.toBool();
            if (m_state == State::Cancelling) { cancelRemote(); return; }
            if (m_state != State::Admitting) return;
            const auto epoch = m_epoch;
            setState(State::Recording, QStringLiteral("Recording…"));
            if (epoch == m_epoch && m_state == State::Recording) emit captureRequested(m_keepOriginal);
        });
}

void GenerationClient::append(const QByteArray &inference, const QByteArray &original, int originalRate, int originalChannels) {
    if (m_state != State::Recording) return;
    buffer("inference", inference, 16000, 1);
    if (m_state != State::Recording) return;
    if (!original.isEmpty() && !m_keepOriginal) { fail(QStringLiteral("Original audio was not authorized for this recording.")); return; }
    buffer("original", original, originalRate, originalChannels);
    pump();
}

void GenerationClient::buffer(const QString &kind, const QByteArray &data, int rate, int channels) {
    if (data.isEmpty()) return;
    if (channels < 1 || channels > 8 || rate < 8000 || rate > 192000
        || data.size() % (channels * 4) || data.size() > 1024 * 1024) {
        fail(QStringLiteral("The audio stream has an invalid format or chunk size."));
        return;
    }
    if (kind == "original") {
        if (m_originalRate && (m_originalRate != rate || m_originalChannels != channels)) {
            fail(QStringLiteral("The original audio format changed during recording."));
            return;
        }
        m_originalRate = rate;
        m_originalChannels = channels;
    }
    auto &pending = kind == "inference" ? m_pendingInference : m_pendingOriginal;
    pending += data;
    // Microphone callbacks can arrive every few milliseconds. Coalesce them so
    // a full 180-second take stays within the server's 4096-chunk sequence limit.
    const int chunkBytes = std::min(rate / 4, (1024 * 1024) / (channels * 4)) * channels * 4;
    while (pending.size() >= chunkBytes && m_state == State::Recording) {
        const auto chunk = pending.first(chunkBytes);
        pending.remove(0, chunkBytes);
        enqueue(kind, chunk, rate, channels);
    }
}

void GenerationClient::enqueue(const QString &kind, const QByteArray &data, int rate, int channels) {
    if (data.isEmpty()) return;
    if (channels < 1 || channels > 8 || rate < 8000 || rate > 192000
        || data.size() % (channels * 4) || data.size() > 1024 * 1024) {
        fail(QStringLiteral("The audio stream has an invalid format or chunk size."));
        return;
    }
    if (m_queuedBytes + data.size() > 8 * 1024 * 1024) {
        fail(QStringLiteral("Audio upload could not keep up. Recording stopped."));
        return;
    }
    auto &sequence = kind == "inference" ? m_inferenceSequence : m_originalSequence;
    auto &frames = kind == "inference" ? m_inferenceFrames : m_originalFrames;
    frames += data.size() / (channels * 4);
    m_queue.enqueue({kind, data, rate, channels, sequence++, frames});
    m_queuedBytes += data.size();
}

void GenerationClient::pump() {
    if (m_sending || !(m_state == State::Recording || m_state == State::Uploading)) return;
    if (m_queue.isEmpty()) {
        if (m_state == State::Uploading) finishUpload();
        return;
    }
    const auto chunk = m_queue.dequeue();
    m_queuedBytes -= chunk.data.size();
    m_sending = true;
    const auto path = QString("/v1/generations/%1/audio/%2?sequence=%3&sampleRate=%4&channels=%5")
        .arg(m_id, chunk.kind).arg(chunk.sequence).arg(chunk.rate).arg(chunk.channels);
    request(path, chunk.data, "application/octet-stream", [this, chunk](const QJsonObject &receipt, const QString &error) {
        m_sending = false;
        if (!(m_state == State::Recording || m_state == State::Uploading)) return;
        if (!error.isEmpty()) { fail(error); return; }
        if (receipt.value("nextSequence").toInteger(-1) != chunk.sequence + 1
            || receipt.value("frameCount").toInteger(-1) != chunk.frames) {
            fail(QStringLiteral("The server did not acknowledge the complete audio chunk."));
            return;
        }
        pump();
    });
}

void GenerationClient::finish() {
    if (m_state != State::Recording) return;
    enqueue("inference", std::exchange(m_pendingInference, {}), 16000, 1);
    if (m_state != State::Recording) return;
    enqueue("original", std::exchange(m_pendingOriginal, {}), m_originalRate, m_originalChannels);
    if (m_state != State::Recording) return;
    setState(State::Uploading, QStringLiteral("Finishing audio upload…"));
    pump();
}

void GenerationClient::finishUpload() {
    if (m_inferenceFrames < 4000 || m_inferenceFrames > 2880000) {
        fail(QStringLiteral("Record between 0.25 and 180 seconds of audio before transcribing."));
        return;
    }
    const auto epoch = m_epoch;
    setState(State::Processing, QStringLiteral("Transcribing…"));
    if (epoch != m_epoch || m_state != State::Processing) return;
    QJsonObject frames{{"inferenceFrames", m_inferenceFrames}};
    if (m_keepOriginal) frames.insert("originalFrames", m_originalFrames);
    request(QString("/v1/generations/%1/finish").arg(m_id), json(frames), "application/json",
        [this](const QJsonObject &record, const QString &error) {
            if (m_state != State::Processing) return;
            if (!error.isEmpty()) { fail(error); return; }
            receiveRecord(record);
            if (m_state == State::Processing) watch();
        });
}

void GenerationClient::watch() {
    auto url = m_endpoint;
    url.setPath(QString("/v1/generations/%1/events").arg(m_id));
    QNetworkRequest request(url);
    request.setTransferTimeout(10000);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    request.setRawHeader("Accept", "application/x-ndjson");
    auto *reply = m_network.get(request);
    reply->setReadBufferSize(maximumRecordBytes + 1);
    m_events = reply;
    m_eventBuffer.clear();
    const auto epoch = m_epoch;
    connect(reply, &QNetworkReply::readyRead, this, [this, reply, epoch] {
        if (epoch != m_epoch || m_state != State::Processing) { reply->abort(); return; }
        const auto httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (httpStatus != 200 || !reply->header(QNetworkRequest::ContentTypeHeader).toString().startsWith("application/x-ndjson")) {
            fail(QStringLiteral("The server did not provide a valid progress stream. Check history before retrying."));
            return;
        }
        while (reply->bytesAvailable() && m_state == State::Processing) {
            m_eventBuffer += reply->read(64 * 1024);
            qsizetype newline;
            while ((newline = m_eventBuffer.indexOf('\n')) >= 0 && m_state == State::Processing) {
                const auto line = m_eventBuffer.left(newline);
                m_eventBuffer.remove(0, newline + 1);
                const auto document = QJsonDocument::fromJson(line);
                if (line.size() > maximumRecordBytes || !document.isObject()) {
                    fail(QStringLiteral("The server sent an invalid progress record."));
                    return;
                }
                receiveRecord(document.object());
            }
            if (m_eventBuffer.size() > maximumRecordBytes) {
                fail(QStringLiteral("The server progress record exceeded its limit."));
                return;
            }
        }
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, epoch] {
        if (m_events == reply) m_events.clear();
        reply->deleteLater();
        if (epoch == m_epoch && m_state == State::Processing) {
            fail(QStringLiteral("The progress connection ended. The server may still finish; check history before retrying."));
        }
    });
}

void GenerationClient::receiveRecord(const QJsonObject &record) {
    if (m_state != State::Processing) return;
    if (record.value("id").toString() != m_id) { fail(QStringLiteral("The progress record belongs to another recording.")); return; }
    const auto status = record.value("status").toString();
    if (status == "completed") {
        const auto text = record.value("insertionText");
        if (!text.isString() || text.toString().toUtf8().size() > 64 * 1024) {
            fail(QStringLiteral("The completed recording has invalid insertion text."));
            return;
        }
        m_transcript = text.toString();
        const auto epoch = m_epoch;
        const auto id = m_id;
        const auto transcript = m_transcript;
        auto events = m_events;
        m_events.clear();
        m_state = State::Completed;
        if (events) events->abort();
        setState(State::Completed, m_transcript.isEmpty() ? QStringLiteral("No speech was detected.")
                                                       : QStringLiteral("Transcript saved on the local server."));
        if (epoch == m_epoch && m_state == State::Completed) emit completed(id, transcript);
    } else if (status == "failed") {
        fail(record.value("error").toString("Transcription failed.").left(500));
    } else if (status == "cancelled") {
        setState(State::Cancelled, QStringLiteral("Recording cancelled."));
        if (m_events) m_events->abort();
    } else if (status == "proofreading") {
        m_status = QStringLiteral("Cleaning up text…"); emit changed();
    } else if (status != "queued" && status != "transcribing") {
        fail(QStringLiteral("The server returned an unexpected recording state."));
    }
}

void GenerationClient::cancel() {
    if (!active() || m_state == State::Cancelling) return;
    const bool waitingAdmission = m_state == State::Admitting;
    setState(State::Cancelling, QStringLiteral("Cancelling…"));
    emit captureMustStop();
    m_queue.clear();
    m_queuedBytes = 0;
    m_pendingInference.clear();
    m_pendingOriginal.clear();
    if (m_events) m_events->abort();
    if (!waitingAdmission) cancelRemote();
}

void GenerationClient::cancelRemote() {
    if (m_id.isEmpty()) { setState(State::Cancelled, QStringLiteral("Recording cancelled.")); return; }
    request(QString("/v1/generations/%1/cancel").arg(m_id), "{}", "application/json",
        [this](const QJsonObject &, const QString &error) {
            if (m_state != State::Cancelling) return;
            setState(State::Cancelled, error.isEmpty() ? QStringLiteral("Recording cancelled.")
                : QStringLiteral("Capture stopped. Server cancellation could not be confirmed; check history."));
        });
}

void GenerationClient::fail(const QString &message) {
    const bool wasCapturing = m_state == State::Recording || m_state == State::Uploading;
    const auto failedId = m_id;
    m_state = State::Failed;
    m_status = message;
    m_queue.clear();
    m_queuedBytes = 0;
    m_pendingInference.clear();
    m_pendingOriginal.clear();
    if (m_events) m_events->abort();
    // An interrupted complete upload may still produce a durable result. Do not
    // cancel it or retry automatically merely because its event stream closed.
    if (wasCapturing && !failedId.isEmpty()) {
        request(QString("/v1/generations/%1/cancel").arg(failedId), "{}", "application/json",
            [](const QJsonObject &, const QString &) {});
    }
    emit captureMustStop();
    emit changed();
}
} // namespace sotto
