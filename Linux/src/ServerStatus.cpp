#include "ServerStatus.h"

#include <QJsonDocument>
#include <QNetworkReply>
#include <QNetworkRequest>

namespace sotto {
HealthStatus parseHealth(const QJsonObject &object) {
    if (object.value("apiVersion").toInt(-1) != 1 || !object.value("ready").isBool()
        || !object.value("speech").isObject()) {
        return {false, false, QStringLiteral("The server returned an unsupported health response.")};
    }
    const bool ready = object.value("ready").toBool();
    return {true, ready, ready ? QStringLiteral("Ready for dictation.")
                              : QStringLiteral("Server connected; speech recognition is not ready or is busy.")};
}

ServerStatus::ServerStatus(QUrl endpoint, QObject *parent)
    : QObject(parent), m_endpoint(std::move(endpoint)), m_network(this) {}

void ServerStatus::refresh() {
    if (m_reply) return;
    const auto host = m_endpoint.host().toLower();
    if (m_endpoint.scheme() != "http" || !(host == "127.0.0.1" || host == "localhost" || host == "::1")
        || !m_endpoint.userInfo().isEmpty() || m_endpoint.hasQuery() || m_endpoint.hasFragment()) {
        m_ready = false;
        m_message = QStringLiteral("Choose an HTTP server on localhost. Remote connections are not enabled.");
        emit changed();
        return;
    }
    auto url = m_endpoint;
    url.setPath("/v1/health");
    QNetworkRequest request(url);
    request.setTransferTimeout(3000);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    request.setRawHeader("Accept", "application/json");
    auto *reply = m_network.get(request);
    m_reply = reply;
    // A health endpoint has no reason to stream unbounded content.
    connect(reply, &QNetworkReply::readyRead, this, [reply] {
        if (reply->bytesAvailable() > 64 * 1024) reply->abort();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        m_ready = false;
        if (reply->error() != QNetworkReply::NoError) {
            m_message = QStringLiteral("Inference server is unavailable. No service was started automatically.");
        } else if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200) {
            m_message = QStringLiteral("The server returned an unexpected HTTP response.");
        } else {
            const auto bytes = reply->read(64 * 1024 + 1);
            QJsonParseError error;
            const auto document = QJsonDocument::fromJson(bytes, &error);
            if (bytes.size() > 64 * 1024 || error.error != QJsonParseError::NoError || !document.isObject()) {
                m_message = QStringLiteral("The server returned invalid health data.");
            } else {
                const auto health = parseHealth(document.object());
                m_ready = health.valid && health.ready;
                m_message = health.message;
            }
        }
        m_reply.clear();
        reply->deleteLater();
        emit changed();
    });
    emit changed();
}
} // namespace sotto
