#include "PcmMeter.h"
#include "AudioConverter.h"
#include "ServerStatus.h"

#include <QJsonObject>
#include <QTcpServer>
#include <QTcpSocket>
#include <QtTest>
#include <QtEndian>
#include <array>
#include <bit>
#include <cmath>
#include <limits>

namespace {
QAudioFormat format(QAudioFormat::SampleFormat sampleFormat, int channels = 2) {
    QAudioFormat result;
    result.setSampleRate(48000);
    result.setChannelCount(channels);
    result.setSampleFormat(sampleFormat);
    return result;
}
template<typename T, size_t N> QByteArray bytes(const std::array<T, N> &values) {
    return QByteArray(reinterpret_cast<const char *>(values.data()), sizeof(values));
}
}

class CoreTests : public QObject {
    Q_OBJECT
private slots:
    void streamingConversionPreservesNativeAudioAndDrainsTail() {
        sotto::AudioConverter converter;
        QVERIFY(converter.configure(format(QAudioFormat::Float, 1), 0, true));
        QVector<float> source(48000);
        for (qsizetype i = 0; i < source.size(); ++i) source[i] = .25F * std::sin(i * 2 * 3.141592653589793 * 1000 / 48000);
        const QByteArray input(reinterpret_cast<const char *>(source.constData()), source.size() * sizeof(float));
        QByteArray original;
        QByteArray inference;
        for (qsizetype offset = 0; offset < input.size(); offset += 997) {
            const auto output = converter.consume(QByteArrayView(input).sliced(offset, std::min<qsizetype>(997, input.size() - offset)));
            QVERIFY2(output.error.isEmpty(), qPrintable(output.error));
            original += output.original;
            inference += output.inference;
        }
        const auto tail = converter.finish();
        QVERIFY2(tail.error.isEmpty(), qPrintable(tail.error));
        inference += tail.inference;
        original += tail.original;
        QCOMPARE(original, input);
        QVERIFY(std::abs(inference.size() / 4 - 16000) <= 1);
        QVERIFY(!converter.finish().error.isEmpty());
    }
    void downsamplingRejectsAboveNyquistAudio() {
        sotto::AudioConverter converter;
        QVERIFY(converter.configure(format(QAudioFormat::Float, 1), 0, false));
        QVector<float> source(48000);
        for (qsizetype i = 0; i < source.size(); ++i) source[i] = .5F * std::sin(i * 2 * 3.141592653589793 * 18000 / 48000);
        const auto data = QByteArrayView(reinterpret_cast<const char *>(source.constData()), source.size() * sizeof(float));
        const auto output = converter.consume(data);
        const auto tail = converter.finish();
        QVERIFY(output.error.isEmpty());
        QVERIFY(tail.error.isEmpty());
        QVERIFY(output.original.isEmpty());
        const auto result = output.inference + tail.inference;
        double squares = 0;
        const auto frames = result.size() / 4;
        for (qsizetype i = 100; i < frames - 100; ++i) {
            const float sample = std::bit_cast<float>(qFromLittleEndian<quint32>(result.constData() + i * 4));
            squares += sample * sample;
        }
        QVERIFY(std::sqrt(squares / (frames - 200)) < .01);
    }
    void incompleteRecordingCannotBeSilentlyConverted() {
        sotto::AudioConverter converter;
        QVERIFY(converter.configure(format(QAudioFormat::Int16, 2), 0, true));
        QVERIFY(converter.consume(QByteArray(3, '\0')).error.isEmpty());
        QVERIFY(!converter.finish().error.isEmpty());
    }
    void conversionUsesOnlyTheChosenChannel() {
        sotto::AudioConverter converter;
        QVERIFY(converter.configure(format(QAudioFormat::Float, 2), 1, false));
        QVector<float> source(96000);
        for (qsizetype i = 0; i < source.size(); i += 2) source[i] = 1;
        const auto output = converter.consume(QByteArrayView(reinterpret_cast<const char *>(source.constData()), source.size() * sizeof(float)));
        const auto tail = converter.finish();
        QVERIFY(output.error.isEmpty());
        QVERIFY(tail.error.isEmpty());
        const auto all = output.inference + tail.inference;
        QCOMPARE(all, QByteArray(all.size(), '\0'));
    }
    void selectedChannelDoesNotMixOtherInputs() {
        sotto::PcmMeter meter;
        QVERIFY(meter.configure(format(QAudioFormat::Float, 6), 1));
        const auto data = bytes(std::array<float, 12>{1, .25F, 1, 1, 1, 1, -1, -.5F, -1, -1, -1, -1});
        const auto result = meter.consume(data);
        QCOMPARE(result.frames, 2);
        QCOMPARE(result.peak, .5F);
        QVERIFY(std::abs(result.rms - std::sqrt((.0625F + .25F) / 2)) < .00001F);
    }
    void incompleteFramesSurviveArbitraryChunkBoundaries() {
        sotto::PcmMeter meter;
        QVERIFY(meter.configure(format(QAudioFormat::Int16), 1));
        const auto data = bytes(std::array<qint16, 4>{32767, 16384, 0, -32768});
        QCOMPARE(meter.consume(QByteArrayView(data).first(3)).frames, 0);
        const auto first = meter.consume(QByteArrayView(data).sliced(3, 2));
        QCOMPARE(first.frames, 1);
        QCOMPARE(first.peak, .5F);
        const auto second = meter.consume(QByteArrayView(data).sliced(5));
        QCOMPARE(second.frames, 1);
        QCOMPARE(second.peak, 1.0F);
    }
    void signed32BitRangeIsNormalized() {
        sotto::PcmMeter meter;
        QVERIFY(meter.configure(format(QAudioFormat::Int32, 1), 0));
        const auto result = meter.consume(bytes(std::array<qint32, 2>{1073741824, -1073741824}));
        QCOMPARE(result.peak, .5F);
        QCOMPARE(result.rms, .5F);
    }
    void unsigned8BitSilenceIsCentered() {
        sotto::PcmMeter meter;
        QVERIFY(meter.configure(format(QAudioFormat::UInt8, 1), 0));
        QCOMPARE(meter.consume(bytes(std::array<quint8, 2>{128, 128})).peak, 0.0F);
    }
    void nonFiniteFloatSamplesDoNotPoisonTheMeter() {
        sotto::PcmMeter meter;
        QVERIFY(meter.configure(format(QAudioFormat::Float, 1), 0));
        const auto result = meter.consume(bytes(std::array<float, 3>{
            std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(), 2.0F}));
        QCOMPARE(result.peak, 1.0F);
        QVERIFY(std::isfinite(result.rms));
    }
    void newRecordingDiscardsPreviousPartialFrame() {
        sotto::PcmMeter meter;
        const auto selected = format(QAudioFormat::Int16, 1);
        QVERIFY(meter.configure(selected, 0));
        meter.consume(QByteArray(1, '\xff'));
        QVERIFY(meter.configure(selected, 0));
        QCOMPARE(meter.consume(bytes(std::array<qint16, 1>{0})).peak, 0.0F);
    }
    void invalidChannelIsRejected() {
        sotto::PcmMeter meter;
        QVERIFY(!meter.configure(format(QAudioFormat::Float), -1));
        QVERIFY(!meter.configure(format(QAudioFormat::Float), 2));
        QCOMPARE(meter.consume(QByteArray(10, '\0')).frames, 0);
    }
    void malformedHealthCannotReportReady() {
        QVERIFY(!sotto::parseHealth({{"ready", true}}).valid);
        QVERIFY(!sotto::parseHealth({{"apiVersion", 2}, {"ready", true}, {"speech", QJsonObject{}}}).valid);
        QVERIFY(!sotto::parseHealth({{"apiVersion", 1}, {"ready", "yes"}, {"speech", QJsonObject{}}}).valid);
    }
    void busyHealthIsConnectedButNotReady() {
        const auto result = sotto::parseHealth({{"apiVersion", 1}, {"ready", false}, {"speech", QJsonObject{}}});
        QVERIFY(result.valid);
        QVERIFY(!result.ready);
    }
    void remoteEndpointIsRejectedBeforeConnecting() {
        sotto::ServerStatus status(QUrl("http://192.0.2.1:8392"));
        status.refresh();
        QVERIFY(!status.checking());
        QVERIFY(!status.ready());
        QVERIFY(status.message().contains("localhost"));
    }
    void localHealthResponseIsReadAsynchronously() {
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        connect(&server, &QTcpServer::newConnection, this, [&server] {
            auto *socket = server.nextPendingConnection();
            connect(socket, &QTcpSocket::readyRead, socket, [socket] {
                socket->readAll();
                const QByteArray body = R"({"apiVersion":1,"ready":true,"speech":{"ready":true}})";
                socket->write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                    + QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n" + body);
                socket->disconnectFromHost();
            });
            connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
        });
        sotto::ServerStatus status(QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())));
        status.refresh();
        QVERIFY(status.checking());
        QTRY_VERIFY_WITH_TIMEOUT(!status.checking(), 1000);
        QVERIFY(status.ready());
    }
    void redirectDoesNotFollowToAnotherEndpoint() {
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        int requests = 0;
        connect(&server, &QTcpServer::newConnection, this, [&server, &requests] {
            auto *socket = server.nextPendingConnection();
            connect(socket, &QTcpSocket::readyRead, socket, [socket, &requests] {
                socket->readAll();
                ++requests;
                socket->write("HTTP/1.1 302 Found\r\nLocation: http://192.0.2.1/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                socket->disconnectFromHost();
            });
            connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
        });
        sotto::ServerStatus status(QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())));
        status.refresh();
        QTRY_VERIFY_WITH_TIMEOUT(!status.checking(), 1000);
        QVERIFY(!status.ready());
        QCOMPARE(requests, 1);
        QVERIFY(status.message().contains("HTTP"));
    }
};

QTEST_GUILESS_MAIN(CoreTests)
#include "CoreTests.moc"
