#include "GenerationClient.h"
#include "PersonalDictionary.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QPointer>
#include <QTemporaryDir>
#include <QTcpServer>
#include <QTcpSocket>
#include <QtTest>
#include <memory>

namespace {
struct Request {
    QString path;
    QByteArray body;
};

// Read complete HTTP requests, including split headers/bodies, so delayed
// acknowledgements exercise the real asynchronous network client.
class LocalServer : public QTcpServer {
public:
    QVector<Request> requests;
    std::function<void(const Request &, QTcpSocket *)> handler;
    LocalServer() {
        connect(this, &QTcpServer::newConnection, this, [this] {
            while (hasPendingConnections()) {
                auto *socket = nextPendingConnection();
                auto buffer = std::make_shared<QByteArray>();
                connect(socket, &QTcpSocket::readyRead, this, [this, socket, buffer] {
                    *buffer += socket->readAll();
                    const auto end = buffer->indexOf("\r\n\r\n");
                    if (end < 0) return;
                    const auto header = buffer->left(end);
                    int length = 0;
                    for (const auto &line : header.split('\n')) {
                        if (line.toLower().startsWith("content-length:")) length = line.mid(15).trimmed().toInt();
                    }
                    if (buffer->size() < end + 4 + length) return;
                    Request request{QString::fromUtf8(header.split(' ').value(1)), buffer->mid(end + 4, length)};
                    requests.append(request);
                    buffer->clear();
                    handler(request, socket);
                });
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
            }
        });
    }
    QUrl endpoint() const { return QUrl(QString("http://127.0.0.1:%1").arg(serverPort())); }
    static void reply(QTcpSocket *socket, const QJsonObject &value, const QByteArray &type = "application/json") {
        const auto body = QJsonDocument(value).toJson(QJsonDocument::Compact) + '\n';
        socket->write("HTTP/1.1 200 OK\r\nContent-Type: " + type + "\r\nContent-Length: "
            + QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n" + body);
        socket->disconnectFromHost();
    }
    static QJsonObject admission(const Request &request, bool original = false) {
        return {{"id", "601bd7e3-1146-4c6f-a4c4-3bd1083476c2"},
            {"requestID", QJsonDocument::fromJson(request.body).object().value("requestID").toString().toUpper()},
            {"settings", QJsonObject{{"preferences", QJsonObject{{"keepOriginalAudio", original}}}}}};
    }
    static QJsonObject record(const QString &status, const QString &text = {}) {
        return {{"id", "601bd7e3-1146-4c6f-a4c4-3bd1083476c2"}, {"status", status},
            {"insertionText", text}, {"finalText", "A larger preview must never replace insertionText."}};
    }
};
}

class GenerationTests : public QObject {
    Q_OBJECT
    QTemporaryDir m_settings;
private slots:
    void initTestCase() {
        QVERIFY(m_settings.isValid());
        qputenv("XDG_CONFIG_HOME", m_settings.path().toUtf8());
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_settings.path());
        QCoreApplication::setOrganizationName("SottoTests");
        QCoreApplication::setApplicationName("GenerationTests");
    }
    void personalWordsAreSentWithoutChangingSharedPreferences() {
        sotto::PersonalDictionary dictionary;
        QVERIFY(dictionary.save("Herdr\nCotto"));
        LocalServer server; QVERIFY(server.listen(QHostAddress::LocalHost));
        server.handler = [&](const Request &request, QTcpSocket *socket) {
            if (request.path == "/v1/generations") {
                const auto body = QJsonDocument::fromJson(request.body).object();
                QCOMPARE(body.value("personalDictionary").toObject(), dictionary.snapshot());
                LocalServer::reply(socket, LocalServer::admission(request));
            } else {
                QVERIFY(request.path.endsWith("/cancel"));
                LocalServer::reply(socket, LocalServer::record("cancelled"));
            }
        };
        sotto::GenerationClient client(server.endpoint());
        QSignalSpy capture(&client, &sotto::GenerationClient::captureRequested);
        client.start(); QTRY_COMPARE(capture.count(), 1);
        client.cancel(); QTRY_VERIFY(!client.active());
        QVERIFY(dictionary.save(""));
    }
    void offlineServerDoesNotCaptureAndExplicitRetryRecovers() {
        LocalServer server; QVERIFY(server.listen(QHostAddress::LocalHost));
        const auto port = server.serverPort();
        sotto::GenerationClient client(server.endpoint()); server.close();
        QSignalSpy capture(&client, &sotto::GenerationClient::captureRequested);
        QSignalSpy completed(&client, &sotto::GenerationClient::completed);
        client.start(); QTRY_VERIFY(!client.active());
        QCOMPARE(capture.count(), 0); QCOMPARE(completed.count(), 0);
        QVERIFY(server.listen(QHostAddress::LocalHost, port));
        server.handler = [&](const Request &request, QTcpSocket *socket) {
            if (request.path == "/v1/generations") LocalServer::reply(socket, LocalServer::admission(request));
            else if (request.path.contains("/audio/")) LocalServer::reply(socket, {{"nextSequence", 1}, {"frameCount", 4000}});
            else if (request.path.endsWith("/finish")) LocalServer::reply(socket, LocalServer::record("completed", "Recovered."));
            else QFAIL("Unexpected request");
        };
        QTest::qWait(50); QCOMPARE(capture.count(), 0); QVERIFY(server.requests.isEmpty());
        client.start(); QTRY_COMPARE(capture.count(), 1);
        client.append(QByteArray(16000, '\0'), {}, 48000, 1); client.finish();
        QTRY_COMPARE(completed.count(), 1); QCOMPARE(client.transcript(), "Recovered.");
    }
    void cancellationBeforeAdmissionNeverOpensCapture() {
        LocalServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        QPointer<QTcpSocket> admissionSocket;
        QJsonObject admission;
        server.handler = [&](const Request &request, QTcpSocket *socket) {
            if (request.path == "/v1/generations") {
                admissionSocket = socket;
                admission = LocalServer::admission(request);
            } else {
                QVERIFY(request.path.endsWith("/cancel"));
                LocalServer::reply(socket, LocalServer::record("cancelled"));
            }
        };
        sotto::GenerationClient client(server.endpoint());
        QSignalSpy capture(&client, &sotto::GenerationClient::captureRequested);
        client.start();
        QTRY_VERIFY(admissionSocket);
        QCOMPARE(capture.count(), 0);
        client.cancel();
        LocalServer::reply(admissionSocket, admission);
        QTRY_VERIFY(!client.active());
        QCOMPARE(capture.count(), 0);
        QCOMPARE(server.requests.size(), 2);
        QVERIFY(client.status().contains("cancelled"));
    }
    void finishWaitsForAcknowledgedStreamsAndUsesOnlyInsertionText() {
        LocalServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        QPointer<QTcpSocket> firstChunk;
        QJsonObject finish;
        server.handler = [&](const Request &request, QTcpSocket *socket) {
            if (request.path == "/v1/generations") LocalServer::reply(socket, LocalServer::admission(request, true));
            else if (request.path.contains("/audio/inference")) firstChunk = socket;
            else if (request.path.contains("/audio/original")) LocalServer::reply(socket, {{"nextSequence", 1}, {"frameCount", 12000}});
            else if (request.path.endsWith("/finish")) {
                finish = QJsonDocument::fromJson(request.body).object();
                LocalServer::reply(socket, LocalServer::record("queued"));
            } else if (request.path.endsWith("/events")) {
                LocalServer::reply(socket, LocalServer::record("completed", "Only this text."), "application/x-ndjson");
            } else QFAIL("Unexpected request");
        };
        sotto::GenerationClient client(server.endpoint());
        QSignalSpy capture(&client, &sotto::GenerationClient::captureRequested);
        QSignalSpy completed(&client, &sotto::GenerationClient::completed);
        client.start();
        QTRY_COMPARE(capture.count(), 1);
        QVERIFY(capture.first().first().toBool());
        for (int i = 0; i < 40; ++i) {
            client.append(QByteArray(400, '\0'), QByteArray(1200, '\0'), 48000, 1);
        }
        client.finish();
        QTRY_VERIFY(firstChunk);
        QCOMPARE(server.requests.size(), 2);
        QVERIFY(finish.isEmpty());
        LocalServer::reply(firstChunk, {{"nextSequence", 1}, {"frameCount", 4000}});
        QTRY_COMPARE(completed.count(), 1);
        QCOMPARE(finish.value("inferenceFrames").toInt(), 4000);
        QCOMPARE(finish.value("originalFrames").toInt(), 12000);
        QCOMPARE(client.transcript(), "Only this text.");
        QVERIFY(!client.active());
        QCOMPARE(server.requests.size(), 5);
    }
    void directBufferReceipts_data() {
        QTest::addColumn<QString>("status");
        QTest::addColumn<bool>("failReport");
        QTest::newRow("inserted") << QString("inserted") << false;
        QTest::newRow("blocked") << QString("blocked") << false;
        QTest::newRow("uncertain") << QString("uncertain") << false;
        QTest::newRow("receipt-http-failure") << QString("inserted") << true;
    }
    void directBufferReceipts() {
        QFETCH(QString, status); QFETCH(bool, failReport);
        LocalServer server; QVERIFY(server.listen(QHostAddress::LocalHost));
        QJsonObject receipt;
        server.handler = [&](const Request &request, QTcpSocket *socket) {
            if (request.path == "/v1/generations") LocalServer::reply(socket, LocalServer::admission(request));
            else if (request.path.contains("/audio/")) LocalServer::reply(socket, {{"nextSequence", 1}, {"frameCount", 4000}});
            else if (request.path.endsWith("/finish")) LocalServer::reply(socket, LocalServer::record("completed", "Keep the transcript."));
            else if (request.path.endsWith("/delivery")) {
                receipt = QJsonDocument::fromJson(request.body).object();
                if (failReport) {
                    socket->write("HTTP/1.1 503 Unavailable\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
                    socket->disconnectFromHost();
                } else LocalServer::reply(socket, LocalServer::record("completed", "Keep the transcript."));
            } else QFAIL("Unexpected request");
        };
        sotto::GenerationClient client(server.endpoint());
        QSignalSpy capture(&client, &sotto::GenerationClient::captureRequested);
        QSignalSpy completed(&client, &sotto::GenerationClient::completed);
        QSignalSpy failed(&client, &sotto::GenerationClient::deliveryReportFailed);
        client.reportDelivery(status, "Not a completed take.");
        QVERIFY(server.requests.isEmpty());
        client.start(); QTRY_COMPARE(capture.count(), 1);
        client.append(QByteArray(16000, '\0'), {}, 48000, 1); client.finish();
        QTRY_COMPARE(completed.count(), 1);
        QVERIFY(client.completedSuccessfully());
        client.reportDelivery(status, "Pi-owned direct-buffer receipt.");
        QTRY_VERIFY(!receipt.isEmpty());
        // Server recordDelivery accepts these public statuses, not the Pi wire vocabulary.
        const auto expected = status == "blocked" ? QString("failed") : status == "uncertain" ? QString("unconfirmed") : status;
        QCOMPARE(receipt.value("status").toString(), expected);
        QVERIFY(QDateTime::fromString(receipt.value("reportedAt").toString(), Qt::ISODateWithMs).isValid());
        if (failReport) QTRY_COMPARE(failed.count(), 1);
        else QCOMPARE(failed.count(), 0);
        QCOMPARE(client.transcript(), "Keep the transcript.");
        QCOMPARE(completed.count(), 1); // Reporting never re-delivers or retries insertion.
    }
    void invalidAcknowledgementStopsCaptureAndCancelsTheTake() {
        LocalServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        server.handler = [&](const Request &request, QTcpSocket *socket) {
            if (request.path == "/v1/generations") LocalServer::reply(socket, LocalServer::admission(request));
            else if (request.path.contains("/audio/")) LocalServer::reply(socket, {{"nextSequence", 1}, {"frameCount", 3999}});
            else {
                QVERIFY(request.path.endsWith("/cancel"));
                LocalServer::reply(socket, LocalServer::record("cancelled"));
            }
        };
        sotto::GenerationClient client(server.endpoint());
        QSignalSpy capture(&client, &sotto::GenerationClient::captureRequested);
        QSignalSpy stop(&client, &sotto::GenerationClient::captureMustStop);
        QSignalSpy completed(&client, &sotto::GenerationClient::completed);
        client.start();
        QTRY_COMPARE(capture.count(), 1);
        client.append(QByteArray(16000, '\0'), {}, 48000, 1);
        client.finish();
        QTRY_COMPARE(stop.count(), 1);
        QTRY_COMPARE(server.requests.size(), 3);
        QCOMPARE(completed.count(), 0);
        QVERIFY(!client.active());
        QVERIFY(client.status().contains("acknowledge"));
    }
    void cancellationWhileFinishingIgnoresLateCompletion() {
        LocalServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        QPointer<QTcpSocket> finishSocket;
        server.handler = [&](const Request &request, QTcpSocket *socket) {
            if (request.path == "/v1/generations") LocalServer::reply(socket, LocalServer::admission(request));
            else if (request.path.contains("/audio/")) LocalServer::reply(socket, {{"nextSequence", 1}, {"frameCount", 4000}});
            else if (request.path.endsWith("/finish")) finishSocket = socket;
            else {
                QVERIFY(request.path.endsWith("/cancel"));
                LocalServer::reply(socket, LocalServer::record("cancelled"));
            }
        };
        sotto::GenerationClient client(server.endpoint());
        QSignalSpy capture(&client, &sotto::GenerationClient::captureRequested);
        QSignalSpy completed(&client, &sotto::GenerationClient::completed);
        client.start();
        QTRY_COMPARE(capture.count(), 1);
        client.append(QByteArray(16000, '\0'), {}, 48000, 1);
        client.finish();
        QTRY_VERIFY(finishSocket);
        client.cancel();
        LocalServer::reply(finishSocket, LocalServer::record("completed", "Do not deliver this."));
        QTRY_VERIFY(!client.active());
        QCOMPARE(completed.count(), 0);
        QVERIFY(client.transcript().isEmpty());
    }
    void lostProgressConnectionKeepsPreviousTextWithoutCancellingCompletedUpload() {
        LocalServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        int takes = 0;
        bool cancelRequested = false;
        server.handler = [&](const Request &request, QTcpSocket *socket) {
            if (request.path == "/v1/generations") {
                ++takes;
                LocalServer::reply(socket, LocalServer::admission(request));
            } else if (request.path.contains("/audio/")) LocalServer::reply(socket, {{"nextSequence", 1}, {"frameCount", 4000}});
            else if (request.path.endsWith("/finish")) LocalServer::reply(socket, LocalServer::record("queued"));
            else if (request.path.endsWith("/events")) {
                LocalServer::reply(socket, LocalServer::record(takes == 1 ? "completed" : "transcribing", "Keep this text."), "application/x-ndjson");
            } else { cancelRequested = true; LocalServer::reply(socket, {}); }
        };
        sotto::GenerationClient client(server.endpoint());
        QSignalSpy capture(&client, &sotto::GenerationClient::captureRequested);
        QSignalSpy completed(&client, &sotto::GenerationClient::completed);
        for (int take = 1; take <= 2; ++take) {
            client.start();
            QTRY_COMPARE(capture.count(), take);
            client.append(QByteArray(16000, '\0'), {}, 48000, 1);
            client.finish();
            QTRY_VERIFY(!client.active());
            QCOMPARE(client.transcript(), "Keep this text.");
        }
        QCOMPARE(completed.count(), 1);
        QVERIFY(!cancelRequested);
        QVERIFY(client.status().contains("check history"));
    }
    void synchronousCancelOnAdmissionDoesNotOpenCapture() {
        LocalServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        server.handler = [](const Request &request, QTcpSocket *socket) {
            LocalServer::reply(socket, request.path == "/v1/generations"
                ? LocalServer::admission(request) : LocalServer::record("cancelled"));
        };
        sotto::GenerationClient client(server.endpoint());
        connect(&client, &sotto::GenerationClient::changed, &client, [&client] {
            if (client.status() == "Recording…") client.cancel();
        });
        QSignalSpy capture(&client, &sotto::GenerationClient::captureRequested);
        client.start();
        QTRY_VERIFY(!client.active());
        QCOMPARE(capture.count(), 0);
    }
};

QTEST_GUILESS_MAIN(GenerationTests)
#include "GenerationTests.moc"
