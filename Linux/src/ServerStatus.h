#pragma once

#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include <QPointer>
#include <QUrl>

class QNetworkReply;

namespace sotto {
struct HealthStatus {
    bool valid = false;
    bool ready = false;
    QString message;
};
HealthStatus parseHealth(const QJsonObject &object);

class ServerStatus : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString endpoint READ endpoint CONSTANT)
    Q_PROPERTY(bool checking READ checking NOTIFY changed)
    Q_PROPERTY(bool ready READ ready NOTIFY changed)
    Q_PROPERTY(QString message READ message NOTIFY changed)
public:
    explicit ServerStatus(QUrl endpoint, QObject *parent = nullptr);
    QString endpoint() const { return m_endpoint.toString(); }
    bool checking() const { return !m_reply.isNull(); }
    bool ready() const { return m_ready; }
    QString message() const { return m_message; }
    Q_INVOKABLE void refresh();
signals:
    void changed();
private:
    QUrl m_endpoint;
    QNetworkAccessManager m_network;
    QPointer<QNetworkReply> m_reply;
    bool m_ready = false;
    QString m_message = QStringLiteral("Server status has not been checked.");
};
} // namespace sotto
