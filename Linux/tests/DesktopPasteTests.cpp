#include "DesktopPaste.h"
#include "TranscriptValidation.h"
#include <QGuiApplication>
#include <QDBusObjectPath>
#include <QDBusMetaType>
#include <QDBusVirtualObject>
#include <QFile>
#include <QSaveFile>
#include <QTemporaryDir>
#include <QSignalSpy>
#include <QUuid>
#include <QtTest>

namespace {
const QString service = "org.freedesktop.portal.Desktop";
const QString root = "/org/freedesktop/portal/desktop";
class Portal : public QDBusVirtualObject {
public:
    QDBusConnection bus = QDBusConnection::connectToBus(QDBusConnection::SessionBus, "paste-fixture");
    QStringList methods;
    QList<QPair<int, uint>> keys;
    QVariantMap devices;
    QString session, request, peer;
    bool waitForStart = false, failKey = false;
    uint responseCode = 0;
    std::function<void(int)> beforeKey;
    bool start() { return bus.registerService(service) && bus.registerVirtualObject(root, this, QDBusConnection::SubPath); }
    ~Portal() override { bus.unregisterObject(root, QDBusConnection::UnregisterTree); bus.unregisterService(service); QDBusConnection::disconnectFromBus(bus.name()); }
    QString introspect(const QString &) const override { return {}; }
    void respond(uint code, const QVariantMap &results) {
        auto signal = QDBusMessage::createTargetedSignal(peer, request, "org.freedesktop.portal.Request", "Response");
        signal.setArguments({code, results}); bus.send(signal);
    }
    bool handleMessage(const QDBusMessage &message, const QDBusConnection &connection) override {
        methods.append(message.member());
        if (message.member() == "NotifyKeyboardKeysym") {
            keys.append({message.arguments()[2].toInt(), message.arguments()[3].toUInt()});
            if (beforeKey) beforeKey(keys.size());
            if (failKey && keys.size() == 2) connection.send(message.createErrorReply(QDBusError::Failed, "test failure"));
            else connection.send(message.createReply());
            return true;
        }
        if (message.member() == "Register" || message.member() == "Close") { connection.send(message.createReply()); return true; }
        const auto options = qdbus_cast<QVariantMap>(message.arguments().last());
        peer = message.service();
        const auto sender = peer.mid(1).replace('.', '_');
        request = root + "/request/" + sender + '/' + options.value("handle_token").toString();
        connection.send(message.createReply(QVariantList{QVariant::fromValue(QDBusObjectPath(request))}));
        if (message.member() == "CreateSession") {
            session = root + "/session/" + sender + '/' + options.value("session_handle_token").toString();
            respond(0, {{"session_handle", session}});
        } else if (message.member() == "SelectDevices") { devices = options; respond(0, {}); }
        else if (message.member() == "Start" && !waitForStart) respond(responseCode, {{"devices", uint(1)}});
        return true;
    }
    void closeSession() {
        auto signal = QDBusMessage::createSignal(session, "org.freedesktop.portal.Session", "Closed");
        signal.setArguments({QVariantMap{}}); bus.send(signal);
    }
};
QByteArray contents(const QString &path) { QFile file(path); if (!file.open(QIODevice::ReadOnly)) return {}; return file.readAll(); }
void save(const QString &path, const QByteArray &bytes) {
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size() || !file.commit()) qFatal("Cannot write clipboard fixture");
}
struct Clipboard {
    QTemporaryDir directory;
    Clipboard() {
        if (!directory.isValid() || !QFile::link(QCoreApplication::applicationFilePath(), copy())
            || !QFile::link(QCoreApplication::applicationFilePath(), read())) qFatal("Cannot create clipboard fixture");
        setText("previous");
    }
    QString copy() const { return directory.filePath("wl-copy"); }
    QString read() const { return directory.filePath("wl-paste"); }
    QByteArray text() const { return contents(directory.filePath("text")); }
    void setText(const QByteArray &text) { save(directory.filePath("text"), text); }
    void flag(const QString &name) { save(directory.filePath(name), "1"); }
};
// The fixture binary doubles as tiny clipboard-owner/read helpers. They use only
// private files and real child lifecycles, never the desktop clipboard or keys.
int clipboardHelper(int argc, char **argv, const QFileInfo &program) {
    QCoreApplication app(argc, argv);
    const QDir directory(program.absolutePath());
    if (program.fileName() == "wl-paste") {
        if (directory.exists("read-error")) return 1;
        if (directory.exists("read-hang")) QThread::msleep(5000);
        if (directory.exists("replace")) save(directory.filePath("text"), "new owner");
        QFile output; if (!output.open(stdout, QIODevice::WriteOnly)) return 1;
        output.write(contents(directory.filePath("text"))); output.flush();
        return 0;
    }
    QFile input; if (!input.open(stdin, QIODevice::ReadOnly)) return 1;
    const auto text = input.readAll();
    save(directory.filePath("text"), text);
    save(directory.filePath("owner.pid"), QByteArray::number(app.applicationPid()));
    QTimer timer; timer.setInterval(5);
    QObject::connect(&timer, &QTimer::timeout, &app, [&] {
        if (contents(directory.filePath("text")) != text || directory.exists("lost")) app.quit();
    });
    timer.start(); return app.exec();
}
}
class DesktopPasteTests : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        QVERIFY(qEnvironmentVariable("SOTTO_TEST_PRIVATE_BUS") == "1");
        QCOMPARE(QGuiApplication::platformName(), "offscreen");
    }
    void transcriptValidationRejectsUnsafeText_data() {
        QTest::addColumn<QString>("text");
        QTest::newRow("empty") << QString();
        QTest::newRow("blank") << QStringLiteral("   ");
        QTest::newRow("lf") << QStringLiteral("first\nsecond");
        QTest::newRow("cr") << QStringLiteral("first\rsecond");
        QTest::newRow("crlf") << QStringLiteral("first\r\nsecond");
        QTest::newRow("tab") << QStringLiteral("first\tsecond");
        QTest::newRow("escape") << QStringLiteral("\x1b[201~command");
        QTest::newRow("nul") << QString(QChar('a')) + QChar::Null + QChar('b');
        QTest::newRow("del") << QString(QChar(0x7f));
        QTest::newRow("next-line") << QString(QChar(0x85));
        QTest::newRow("unicode-line") << QString(QChar(0x2028));
        QTest::newRow("unicode-paragraph") << QString(QChar(0x2029));
        QTest::newRow("bidi-override") << QString(QChar(0x202e));
        QTest::newRow("supplementary-format-control") << QString::fromUtf8("\U000E0001");
        QTest::newRow("invalid-surrogate") << QString(QChar(0xd800));
        QTest::newRow("too-large") << QString(65537, QChar('x'));
        QTest::newRow("utf8-limit") << QString(32769, QChar(0xe9));
    }
    void transcriptValidationRejectsUnsafeText() {
        QFETCH(QString, text);
        const auto original = text;
        QVERIFY(!sotto::transcriptRejection(text).isEmpty());
        QCOMPARE(text, original);
    }
    void transcriptValidationPreservesSingleLineUnicode() {
        const auto text = QString::fromUtf8("Café 日本語 😀 $HOME; not automatically submitted");
        QVERIFY(sotto::transcriptRejection(text).isEmpty());
    }
    void permissionIsExplicitAndKeyboardOnly() {
        Portal portal; QVERIFY(portal.start()); Clipboard clipboard;
        sotto::DesktopPaste paste(nullptr, clipboard.copy(), clipboard.read());
        QTest::qWait(20); QVERIFY(portal.methods.isEmpty()); QVERIFY(!paste.ready());
        paste.setup(); QTRY_VERIFY(paste.ready());
        QCOMPARE(portal.devices.value("types").toUInt(), uint(1));
        QVERIFY(!portal.devices.contains("persist_mode"));
        QCOMPARE(portal.methods, QStringList({"Register", "CreateSession", "SelectDevices", "Start"}));
        QVERIFY(portal.keys.isEmpty()); QCOMPARE(clipboard.text(), "previous");
    }
    void unicodePasteUsesOnlyOneFixedChordAndLeavesClipboard() {
        Portal portal; QVERIFY(portal.start()); Clipboard clipboard;
        sotto::DesktopPaste paste(nullptr, clipboard.copy(), clipboard.read());
        paste.setup(); QTRY_VERIFY(paste.ready()); QSignalSpy result(&paste, &sotto::DesktopPaste::finished);
        paste.paste(QString::fromUtf8("café 世界")); paste.paste("duplicate");
        QTRY_COMPARE(result.count(), 1);
        const QList<QPair<int, uint>> expected{{0xffe3,1},{0xffe1,1},{0x76,1},{0x76,0},{0xffe1,0},{0xffe3,0}};
        QCOMPARE(portal.keys, expected); QCOMPARE(result.first()[0].toString(), "uncertain");
        QCOMPARE(clipboard.text(), QByteArray("café 世界")); QVERIFY(!paste.busy());
        paste.paste("second take"); QTRY_COMPARE(result.count(), 2);
        QCOMPARE(portal.keys.size(), 12); QCOMPARE(clipboard.text(), "second take");
    }
    void unsafeTextAndMissingPermissionDoNotTouchClipboard() {
        Portal portal; QVERIFY(portal.start()); Clipboard clipboard;
        sotto::DesktopPaste paste(nullptr, clipboard.copy(), clipboard.read());
        QSignalSpy result(&paste, &sotto::DesktopPaste::finished);
        paste.paste("not authorized"); QCOMPARE(result.count(), 1);
        paste.setup(); QTRY_VERIFY(paste.ready());
        for (const auto &text : {QString("command\n"), QString("\x1b[31m"), QString(70000, 'x'), QString("   ")}) paste.paste(text);
        QCOMPARE(result.count(), 5); QVERIFY(portal.keys.isEmpty()); QCOMPARE(clipboard.text(), "previous");
    }
    void cancellationAndClipboardReplacementPreventDispatch() {
        Portal portal; QVERIFY(portal.start()); Clipboard clipboard;
        sotto::DesktopPaste paste(nullptr, clipboard.copy(), clipboard.read());
        paste.setup(); QTRY_VERIFY(paste.ready()); QSignalSpy result(&paste, &sotto::DesktopPaste::finished);
        paste.paste("cancelled"); paste.cancel(); QTest::qWait(100);
        QVERIFY(portal.keys.isEmpty()); QCOMPARE(result.count(), 1);
        clipboard.flag("replace"); paste.paste("old clipboard");
        QTRY_COMPARE(result.count(), 2); QVERIFY(portal.keys.isEmpty()); QCOMPARE(clipboard.text(), "new owner");
    }
    void clipboardChangeAfterModifiersReleasesWithoutV() {
        Portal portal; QVERIFY(portal.start()); Clipboard clipboard;
        sotto::DesktopPaste paste(nullptr, clipboard.copy(), clipboard.read());
        portal.beforeKey = [&](int count) { if (count == 2) clipboard.setText("new owner"); };
        paste.setup(); QTRY_VERIFY(paste.ready()); QSignalSpy result(&paste, &sotto::DesktopPaste::finished);
        paste.paste("test"); QTRY_COMPARE(result.count(), 1);
        QCOMPARE(result.first()[0].toString(), "uncertain");
        QTRY_VERIFY(portal.keys.contains(qMakePair(0xffe3, uint(0))));
        QVERIFY(!portal.keys.contains(qMakePair(0x76, uint(1)))); QCOMPARE(clipboard.text(), "new owner");
    }
    void missingToolsAndReadFailureNeverDispatch() {
        Portal portal; QVERIFY(portal.start()); Clipboard clipboard;
        for (bool missing : {true, false}) {
            sotto::DesktopPaste paste(nullptr, missing ? clipboard.directory.filePath("absent") : clipboard.copy(), clipboard.read());
            paste.setup(); QTRY_VERIFY(paste.ready()); QSignalSpy result(&paste, &sotto::DesktopPaste::finished);
            clipboard.flag("read-error"); paste.paste("test"); QTRY_COMPARE(result.count(), 1);
            QCOMPARE(result.first()[0].toString(), "blocked"); QVERIFY(portal.keys.isEmpty());
        }
    }
    void readTimeoutAndLostOwnershipNeverDispatch() {
        Portal portal; QVERIFY(portal.start()); Clipboard clipboard;
        sotto::DesktopPaste paste(nullptr, clipboard.copy(), clipboard.read());
        paste.setup(); QTRY_VERIFY(paste.ready()); QSignalSpy result(&paste, &sotto::DesktopPaste::finished);
        clipboard.flag("read-hang"); paste.paste("test"); QTRY_COMPARE(result.count(), 1);
        QVERIFY(portal.keys.isEmpty()); QCOMPARE(result.first()[0].toString(), "blocked");
        clipboard.flag("lost"); paste.paste("new take"); QTRY_COMPARE(result.count(), 2);
        QVERIFY(portal.keys.isEmpty());
    }
    void keyFailureReleasesAndDisablesWithoutRetry() {
        Portal portal; portal.failKey = true; QVERIFY(portal.start()); Clipboard clipboard;
        sotto::DesktopPaste paste(nullptr, clipboard.copy(), clipboard.read());
        paste.setup(); QTRY_VERIFY(paste.ready()); QSignalSpy result(&paste, &sotto::DesktopPaste::finished);
        paste.paste("test"); QTRY_COMPARE(result.count(), 1); QTRY_VERIFY(portal.methods.contains("Close"));
        QVERIFY(!paste.ready()); QCOMPARE(result.first()[0].toString(), "uncertain");
        QVERIFY(!portal.keys.contains(qMakePair(0x76, uint(1)))); QVERIFY(portal.keys.contains(qMakePair(0xffe3, uint(0))));
    }
    void declineCanBeRetriedExplicitlyAndLateGrantCannotRevive() {
        Portal portal; portal.responseCode = 1; QVERIFY(portal.start()); Clipboard clipboard;
        sotto::DesktopPaste paste(nullptr, clipboard.copy(), clipboard.read());
        paste.setup(); QTRY_VERIFY(!paste.busy()); QVERIFY(!paste.ready());
        portal.waitForStart = true; paste.setup(); QTRY_COMPARE(portal.methods.count("Start"), 2);
        paste.disconnectPaste(); portal.respond(0, {{"devices", uint(1)}}); QTest::qWait(30);
        QVERIFY(!paste.ready()); QVERIFY(!paste.busy()); QCOMPARE(portal.methods.count("Register"), 1);
    }
    void sessionLossCancelsPendingPaste() {
        Portal portal; QVERIFY(portal.start()); Clipboard clipboard;
        sotto::DesktopPaste paste(nullptr, clipboard.copy(), clipboard.read());
        paste.setup(); QTRY_VERIFY(paste.ready()); QSignalSpy result(&paste, &sotto::DesktopPaste::finished);
        paste.paste("stale"); portal.closeSession();
        QTRY_VERIFY(!paste.ready()); QCOMPARE(result.count(), 1); QVERIFY(portal.keys.isEmpty());
        QCOMPARE(portal.methods.count("CreateSession"), 1);
    }
    void liveWaylandClipboardOnly() {
        if (!qEnvironmentVariableIsSet("SOTTO_TEST_WAYLAND_CLIPBOARD")) QSKIP("Explicit clipboard-only opt-in required. Keyboard events remain isolated.");
        Portal portal; QVERIFY(portal.start());
        QProcess reader; reader.start("wl-paste", {"--list-types"});
        QVERIFY(reader.waitForFinished(2000)); QCOMPARE(reader.exitCode(), 0);
        for (const auto &type : reader.readAllStandardOutput().trimmed().split('\n'))
            if (type != "text/plain" && type != "text/plain;charset=utf-8" && type != "UTF8_STRING" && type != "STRING" && type != "TEXT")
                QSKIP("Preserve non-plain-text clipboard data; live probe not run.");
        reader.start("wl-paste", {"--no-newline", "--type", "text/plain;charset=utf-8"});
        QVERIFY(reader.waitForFinished(2000)); QCOMPARE(reader.exitCode(), 0);
        const auto previous = reader.readAllStandardOutput();
        if (QString::fromUtf8(previous).toUtf8() != previous || !sotto::transcriptRejection(QString::fromUtf8(previous)).isEmpty())
            QSKIP("Cannot restore this clipboard through the single-line fixture; live probe not run.");
        const auto text = "cotto clipboard probe " + QUuid::createUuid().toString();
        sotto::DesktopPaste paste; paste.setup(); QTRY_VERIFY(paste.ready());
        QSignalSpy result(&paste, &sotto::DesktopPaste::finished);
        paste.paste(text); QTRY_COMPARE(result.count(), 1);
        reader.start("wl-paste", {"--no-newline", "--type", "text/plain;charset=utf-8"});
        QVERIFY(reader.waitForFinished(2000)); const bool matches = reader.readAllStandardOutput() == text.toUtf8();
        if (matches && !previous.trimmed().isEmpty()) {
            // Restore plain text only while our probe still owns the clipboard.
            // The keyboard recipient is still the private fake portal.
            paste.paste(QString::fromUtf8(previous)); QTRY_COMPARE(result.count(), 2);
            QCOMPARE(result.last()[0].toString(), "uncertain");
            reader.start("wl-paste", {"--no-newline", "--type", "text/plain;charset=utf-8"});
            QVERIFY(reader.waitForFinished(2000)); QVERIFY(reader.readAllStandardOutput() == previous);
        }
        QVERIFY(matches); QCOMPARE(result.first()[0].toString(), "uncertain");
        const QList<QPair<int, uint>> expected{{0xffe3,1},{0xffe1,1},{0x76,1},{0x76,0},{0xffe1,0},{0xffe3,0}};
        QCOMPARE(portal.keys.mid(0, 6), expected);
    }
};
int main(int argc, char **argv) {
    const QFileInfo program(QString::fromLocal8Bit(argv[0]));
    if (program.fileName() == "wl-copy" || program.fileName() == "wl-paste") return clipboardHelper(argc, argv, program);
    if (qEnvironmentVariable("QT_QPA_PLATFORM") != "offscreen" || qEnvironmentVariable("SOTTO_TEST_PRIVATE_BUS") != "1") return 2;
    QGuiApplication app(argc, argv); DesktopPasteTests tests; return QTest::qExec(&tests, argc, argv);
}
#include "DesktopPasteTests.moc"
