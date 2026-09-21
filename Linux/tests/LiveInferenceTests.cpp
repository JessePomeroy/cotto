#include "AudioConverter.h"
#include "GenerationClient.h"

#include <QFile>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QTemporaryDir>
#include <QtTest>

class LiveInferenceTests : public QObject {
    Q_OBJECT
private slots:
    void publicSpeechFixtureThroughTheQtClient() {
        const auto endpoint = qEnvironmentVariable("SOTTO_TEST_ENDPOINT");
        const auto fixture = qEnvironmentVariable("SOTTO_TEST_PCM16");
        if (endpoint.isEmpty() || fixture.isEmpty()) QSKIP("Set SOTTO_TEST_ENDPOINT and SOTTO_TEST_PCM16 for an isolated Dev server and public mono 16 kHz PCM16 fixture.");
        const QUrl url(endpoint);
        QVERIFY(url.scheme() == "http" && url.host() == "127.0.0.1");
        QNetworkAccessManager network;
        auto healthUrl = url;
        healthUrl.setPath("/v1/health");
        QNetworkRequest request(healthUrl);
        request.setTransferTimeout(3000);
        request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
        auto *health = network.get(request);
        QSignalSpy healthFinished(health, &QNetworkReply::finished);
        QVERIFY(healthFinished.wait(4000));
        QCOMPARE(health->error(), QNetworkReply::NoError);
        const auto status = QJsonDocument::fromJson(health->readAll()).object();
        QVERIFY(status.value("isDev").toBool());
        QVERIFY(status.value("ready").toBool());
        health->deleteLater();

        QTemporaryDir settings;
        QVERIFY(settings.isValid());
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, settings.path());
        QCoreApplication::setOrganizationName("SottoTests");
        QCoreApplication::setApplicationName("LiveInferenceTests");
        QFile input(fixture);
        QVERIFY(input.open(QIODevice::ReadOnly));
        QVERIFY(input.size() > 0 && input.size() <= 16000 * 180 * 2 && input.size() % 2 == 0);
        const auto pcm = input.readAll();
        sotto::GenerationClient client(url);
        sotto::AudioConverter converter;
        QAudioFormat format;
        format.setSampleRate(16000);
        format.setChannelCount(1);
        format.setSampleFormat(QAudioFormat::Int16);
        connect(&client, &sotto::GenerationClient::captureRequested, &client, [&](bool keepOriginal) {
            QVERIFY(converter.configure(format, 0, keepOriginal));
            for (qsizetype offset = 0; offset < pcm.size(); offset += 8192) {
                const auto audio = converter.consume(QByteArrayView(pcm).sliced(offset, std::min<qsizetype>(8192, pcm.size() - offset)));
                QVERIFY(audio.error.isEmpty());
                client.append(audio.inference, audio.original, 16000, 1);
            }
            const auto tail = converter.finish();
            QVERIFY(tail.error.isEmpty());
            client.append(tail.inference, tail.original, 16000, 1);
            client.finish();
        });
        QSignalSpy completed(&client, &sotto::GenerationClient::completed);
        client.start();
        QTRY_VERIFY_WITH_TIMEOUT(!client.active(), 60000);
        QVERIFY2(completed.count() == 1, qPrintable(client.status()));
        QVERIFY(client.transcript().contains("country", Qt::CaseInsensitive));
        qInfo().noquote() << "Public fixture saved as generation" << completed.first().first().toString();
    }
};

QTEST_GUILESS_MAIN(LiveInferenceTests)
#include "LiveInferenceTests.moc"
