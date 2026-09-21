#include "PiDictationBridge.h"
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QJsonDocument>
#include <QLocalSocket>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QTextStream>
#include <QUuid>

using sotto::PiDictationBridge;
namespace {
QString uuid() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
void command(QLocalSocket &socket, const QString &id, const QString &op, const QString &status = {}) {
    QJsonObject object{{"v", 2}, {"id", id}, {"op", op}};
    if (!status.isEmpty()) object.insert("status", status);
    socket.write(QJsonDocument(object).toJson(QJsonDocument::Compact) + '\n');
}
QJsonObject next(QLocalSocket &socket) {
    QElapsedTimer clock; clock.start();
    while (!socket.canReadLine() && clock.elapsed() < 2000) QTest::qWait(1);
    return QJsonDocument::fromJson(socket.readLine()).object();
}
struct Fixture {
    QTemporaryDir directory;
    PiDictationBridge bridge;
    QLocalSocket client;
    QString id;
    QSignalSpy starts{&bridge, &PiDictationBridge::startRequested};
    QSignalSpy stops{&bridge, &PiDictationBridge::stopRequested};
    QSignalSpy cancels{&bridge, &PiDictationBridge::cancelRequested};
    QSignalSpy receipts{&bridge, &PiDictationBridge::receipt};
    bool open() {
        if (!bridge.listen(directory.filePath("input.sock"))) return false;
        client.connectToServer(directory.filePath("input.sock"));
        const auto hello = next(client);
        id = hello.value("id").toString();
        return hello.value("event") == "hello" && hello.value("v") == 2 && !QUuid(id).isNull();
    }
};
}
class PiBridgeTests : public QObject {
    Q_OBJECT
private slots:
    void roundTripAndReceipt() {
        Fixture f; QVERIFY(f.open()); const auto id = f.id;
        command(f.client, id, "start"); QTRY_COMPARE(f.starts.count(), 1);
        f.bridge.recording(id); QCOMPARE(next(f.client).value("event"), "recording");
        command(f.client, id, "stop"); QTRY_COMPARE(f.stops.count(), 1);
        QCOMPARE(next(f.client).value("event"), "processing");
        f.bridge.complete(id, QString::fromUtf8("café 世界"));
        const auto result = next(f.client); QCOMPARE(result.value("text"), QString::fromUtf8("café 世界"));
        command(f.client, id, "receipt", "inserted");
        QTRY_COMPARE(f.receipts.count(), 1); QCOMPARE(f.receipts.at(0).at(1).toString(), "inserted");
        QCOMPARE(f.cancels.count(), 0);
        command(f.client, id, "start"); QCOMPARE(next(f.client).value("event"), "error");
        QCOMPARE(f.starts.count(), 1);
    }
    void disconnectCancelsOnlyOwner() {
        Fixture f; QVERIFY(f.open()); const auto id = f.id;
        command(f.client, id, "start"); QTRY_COMPARE(f.starts.count(), 1);
        f.client.abort(); QTRY_COMPARE(f.cancels.count(), 1);
        QCOMPARE(f.cancels.at(0).at(0).toString(), id);
        f.bridge.complete(id, "late result"); QCOMPARE(f.receipts.count(), 0);
    }
    void missingReceiptIsUncertain() {
        Fixture f; QVERIFY(f.open()); const auto id = f.id;
        command(f.client, id, "start"); QTRY_COMPARE(f.starts.count(), 1);
        f.bridge.recording(id); next(f.client);
        f.bridge.complete(id, "result"); QCOMPARE(next(f.client).value("event"), "transcript");
        f.client.abort(); QTRY_COMPARE(f.receipts.count(), 1);
        QCOMPARE(f.receipts.at(0).at(1).toString(), "uncertain"); QCOMPARE(f.cancels.count(), 0);
    }
    void receiptDeadlineIsUncertain() {
        Fixture f; QVERIFY(f.open()); const auto id = f.id;
        command(f.client, id, "start"); QTRY_COMPARE(f.starts.count(), 1);
        f.bridge.recording(id); next(f.client); f.bridge.complete(id, "result"); next(f.client);
        QTRY_COMPARE_WITH_TIMEOUT(f.receipts.count(), 1, 6500);
        QCOMPARE(f.receipts.at(0).at(1).toString(), "uncertain");
    }
    void cancellationAndReplayAcrossConnections() {
        Fixture f; QVERIFY(f.open()); const auto id = f.id;
        command(f.client, id, "start"); QTRY_COMPARE(f.starts.count(), 1);
        command(f.client, id, "cancel"); QCOMPARE(next(f.client).value("event"), "cancelled");
        QTRY_COMPARE(f.cancels.count(), 1);
        f.client.disconnectFromServer(); QTest::qWait(20);
        f.client.connectToServer(f.directory.filePath("input.sock")); QCOMPARE(next(f.client).value("event"), "hello");
        command(f.client, id, "start"); QCOMPARE(next(f.client).value("event"), "error"); QCOMPARE(f.starts.count(), 1);
    }
    void moreThan4096TakesKeepReplayProtection() {
        Fixture f; QVERIFY(f.open());
        const auto first = f.id;
        QString id = first;
        for (int count = 0; count < 4100; ++count) {
            command(f.client, id, "start");
            command(f.client, id, "cancel");
            QCOMPARE(next(f.client).value("event"), "cancelled");
            QCOMPARE(f.starts.count(), count + 1);
            f.client.abort();
            QCoreApplication::processEvents();
            f.client.connectToServer(f.directory.filePath("input.sock"));
            const auto hello = next(f.client);
            QCOMPARE(hello.value("event"), "hello");
            id = hello.value("id").toString();
            QVERIFY(id != first);
        }
        command(f.client, first, "start");
        QCOMPARE(next(f.client).value("event"), "error");
        QCOMPARE(f.starts.count(), 4100);
        command(f.client, id, "start");
        command(f.client, id, "cancel");
        QCOMPARE(next(f.client).value("event"), "cancelled");
        QCOMPARE(f.starts.count(), 4101);
        command(f.client, id, "start");
        QCOMPARE(next(f.client).value("event"), "error");
        QCOMPARE(f.starts.count(), 4101);
    }
    void legacyProtocolCannotStartCapture() {
        Fixture f; QVERIFY(f.open());
        const auto frame = QJsonObject{{"v", 1}, {"id", f.id}, {"op", "start"}};
        f.client.write(QJsonDocument(frame).toJson(QJsonDocument::Compact) + '\n');
        QTRY_COMPARE(f.client.state(), QLocalSocket::UnconnectedState);
        QCOMPARE(f.starts.count(), 0);
    }
    void rejectedOfferCannotBeReused() {
        Fixture f; QVERIFY(f.open());
        command(f.client, f.id, "start"); QTRY_COMPARE(f.starts.count(), 1);
        f.bridge.reject(f.id, "Busy");
        QCOMPARE(next(f.client).value("event"), "error");
        command(f.client, f.id, "start");
        QCOMPARE(next(f.client).value("event"), "error");
        QCOMPARE(f.starts.count(), 1);
    }
    void secondClientCannotTakeOwnership() {
        Fixture f; QVERIFY(f.open()); QLocalSocket other;
        other.connectToServer(f.directory.filePath("input.sock"));
        QTRY_COMPARE(other.state(), QLocalSocket::UnconnectedState);
        const auto id = f.id; command(f.client, id, "start"); QTRY_COMPARE(f.starts.count(), 1);
        QCOMPARE(f.cancels.count(), 0);
    }
    void malformedOrWrongTakeCancels_data() {
        QTest::addColumn<QByteArray>("line");
        QTest::newRow("oversized") << QByteArray(4097, 'x');
        QTest::newRow("invalid-json") << QByteArray("{\n");
        QTest::newRow("wrong-id") << QJsonDocument(QJsonObject{{"v", 2}, {"op", "stop"}, {"id", uuid()}}).toJson(QJsonDocument::Compact) + '\n';
        QTest::newRow("extra-field") << QByteArray("{\"v\":2,\"op\":\"start\",\"id\":\"00000000-0000-4000-8000-000000000001\",\"text\":\"no\"}\n");
    }
    void malformedOrWrongTakeCancels() {
        QFETCH(QByteArray, line); Fixture f; QVERIFY(f.open()); const auto id = f.id;
        command(f.client, id, "start"); QTRY_COMPARE(f.starts.count(), 1);
        f.client.write(line); QTRY_COMPARE(f.cancels.count(), 1);
    }
    void unsafeTranscriptIsBlocked() {
        Fixture f; QVERIFY(f.open()); const auto id = f.id;
        command(f.client, id, "start"); QTRY_COMPARE(f.starts.count(), 1);
        f.bridge.recording(id); next(f.client); f.bridge.complete(id, "one\ntwo");
        QCOMPARE(next(f.client).value("event"), "error"); QCOMPARE(f.receipts.count(), 1);
        QCOMPARE(f.receipts.at(0).at(1).toString(), "blocked");
    }
    void doesNotReplaceExistingEndpoint() {
        QTemporaryDir directory; const auto path = directory.filePath("input.sock");
        QFile file(path); QVERIFY(file.open(QIODevice::WriteOnly)); file.write("preserve"); file.close();
        { PiDictationBridge bridge; QVERIFY(!bridge.listen(path)); }
        QVERIFY(file.open(QIODevice::ReadOnly)); QCOMPARE(file.readAll(), "preserve");
    }
    void doesNotReplaceActiveListener() {
        Fixture f; QVERIFY(f.open());
        { PiDictationBridge competing; QVERIFY(!competing.listen(f.directory.filePath("input.sock"))); }
        command(f.client, f.id, "start"); QTRY_COMPARE(f.starts.count(), 1);
    }
    void preservesListenerWithoutOurLockFile() {
        QTemporaryDir directory; const auto path = directory.filePath("input.sock");
        QLocalServer legacy; QVERIFY(legacy.listen(path));
        { PiDictationBridge bridge; QVERIFY(!bridge.listen(path)); }
        QLocalSocket client; client.connectToServer(path); QVERIFY(client.waitForConnected(100));
    }
    void preservesSymlinkEndpoint() {
        QTemporaryDir directory; QFile file(directory.filePath("notes"));
        QVERIFY(file.open(QIODevice::WriteOnly)); file.write("keep"); file.close();
        const auto path = directory.filePath("input.sock"); QVERIFY(file.link(path));
        { PiDictationBridge bridge; QVERIFY(!bridge.listen(path)); }
        QVERIFY(QFileInfo(path).isSymLink());
        QVERIFY(file.open(QIODevice::ReadOnly)); QCOMPARE(file.readAll(), "keep");
    }
    void recoversSocketAfterProcessCrash() {
        QTemporaryDir directory; const auto path = directory.filePath("input.sock");
        QProcess process;
        process.start(QCoreApplication::applicationFilePath(), {"--fixture", path});
        QVERIFY(process.waitForStarted());
        QTRY_VERIFY(QFileInfo::exists(path));
        process.kill(); QVERIFY(process.waitForFinished());
        QVERIFY(QFileInfo::exists(path));
        PiDictationBridge bridge; QVERIFY2(bridge.listen(path), qPrintable(bridge.errorString()));
        QLocalSocket client; client.connectToServer(path);
        QCOMPARE(next(client).value("event"), "hello");
    }
    void rejectsPublicDirectory() {
        QTemporaryDir directory;
        QVERIFY(QFile::setPermissions(directory.path(), QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner | QFile::ReadOther));
        PiDictationBridge bridge; QVERIFY(!bridge.listen(directory.filePath("input.sock")));
    }
};
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    // Isolated real-wire adapter fixture. No CaptureController, microphone,
    // inference server, desktop permissions, or live Pi session is involved.
    if (app.arguments().size() == 3 && app.arguments().at(1) == "--fixture") {
        PiDictationBridge bridge;
        if (!bridge.listen(app.arguments().at(2))) return 1;
        QObject::connect(&bridge, &PiDictationBridge::startRequested, &bridge, &PiDictationBridge::recording);
        QObject::connect(&bridge, &PiDictationBridge::stopRequested, &bridge, [&](const QString &id) { bridge.complete(id, QString::fromUtf8("café 世界")); });
        QObject::connect(&bridge, &PiDictationBridge::receipt, &app, [](const QString &, const QString &status) { QTextStream(stdout) << "receipt:" << status << Qt::endl; });
        QTextStream(stdout) << "ready" << Qt::endl;
        return app.exec();
    }
    PiBridgeTests tests; return QTest::qExec(&tests, argc, argv);
}
#include "PiBridgeTests.moc"
