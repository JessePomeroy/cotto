#include "DesktopShortcuts.h"

#include <QDBusVirtualObject>
#include <QSignalSpy>
#include <QtTest>

namespace {
const QString root = "/org/freedesktop/portal/desktop";
const QString portal = "org.freedesktop.portal.Desktop";
const QString shortcutInterface = "org.freedesktop.portal.GlobalShortcuts";

class FakeDesktop : public QDBusVirtualObject {
public:
    QDBusConnection bus = QDBusConnection::connectToBus(QDBusConnection::SessionBus, "fake-desktop");
    QStringList methods;
    sotto::PortalShortcuts bindings;
    QString session;
    QString pendingPath;
    QString destination;
    bool holdBinding = false;
    uint bindResponse = 0;
    int lockReads = 0;
    bool registered = false;
    bool start() {
        registered = bus.registerService(portal) && bus.registerService("org.freedesktop.ScreenSaver")
            && bus.registerVirtualObject(root, this, QDBusConnection::SubPath)
            && bus.registerVirtualObject("/ScreenSaver", this, QDBusConnection::SubPath);
        return registered;
    }
    ~FakeDesktop() override {
        bus.unregisterObject(root, QDBusConnection::UnregisterTree);
        bus.unregisterObject("/ScreenSaver", QDBusConnection::UnregisterTree);
        bus.unregisterService(portal);
        bus.unregisterService("org.freedesktop.ScreenSaver");
        QDBusConnection::disconnectFromBus(bus.name());
    }
    QString introspect(const QString &) const override { return {}; }
    bool handleMessage(const QDBusMessage &message, const QDBusConnection &connection) override {
        if (message.member() == "GetActive") {
            ++lockReads;
            connection.send(message.createReply(QVariantList{false}));
            return true;
        }
        methods.append(message.member());
        if (message.member() == "Register" || message.member() == "Close" || message.member() == "ConfigureShortcuts") {
            connection.send(message.createReply());
            return true;
        }
        const auto options = qdbus_cast<QVariantMap>(message.arguments().last());
        const auto peer = message.service().mid(1).replace('.', '_');
        pendingPath = root + "/request/" + peer + '/' + options.value("handle_token").toString();
        destination = message.service();
        connection.send(message.createReply(QVariantList{QVariant::fromValue(QDBusObjectPath(pendingPath))}));
        if (message.member() == "CreateSession") {
            session = root + "/session/" + peer + '/' + options.value("session_handle_token").toString();
            respond(0, {{"session_handle", session}});
        } else if (message.member() == "BindShortcuts") {
            bindings = qdbus_cast<sotto::PortalShortcuts>(message.arguments().at(1));
            if (!holdBinding) finishBinding();
        } else return false;
        return true;
    }
    void respond(uint code, const QVariantMap &results) {
        auto response = QDBusMessage::createTargetedSignal(destination, pendingPath, "org.freedesktop.portal.Request", "Response");
        response.setArguments({code, results});
        bus.send(response);
    }
    void finishBinding() {
        auto result = bindings;
        for (auto &entry : result) {
            entry.properties.insert("trigger_description", "Test keys: " + entry.id);
            entry.properties.remove("preferred_trigger");
        }
        respond(bindResponse, {{"shortcuts", QVariant::fromValue(result)}});
    }
    void key(const QString &signal, const QString &id, const QString &handle = {}) {
        auto event = QDBusMessage::createSignal(root, shortcutInterface, signal);
        event.setArguments({QVariant::fromValue(QDBusObjectPath(handle.isEmpty() ? session : handle)), id,
            QVariant::fromValue<qulonglong>(1234), QVariantMap{}});
        bus.send(event);
    }
    void lock(bool active) {
        auto event = QDBusMessage::createSignal("/ScreenSaver", "org.freedesktop.ScreenSaver", "ActiveChanged");
        event.setArguments({active}); bus.send(event);
    }
    void closeSession() {
        auto event = QDBusMessage::createSignal(session, "org.freedesktop.portal.Session", "Closed");
        event.setArguments({QVariantMap{}}); bus.send(event);
    }
};
}

class ShortcutTests : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        QVERIFY2(qEnvironmentVariable("SOTTO_TEST_PRIVATE_BUS") == "1", "Run this suite with dbus-run-session through CTest; never use the real desktop bus.");
    }
    void constructionDoesNotRequestShortcutPermission() {
        FakeDesktop desktop;
        QVERIFY(desktop.start());
        sotto::DesktopShortcuts shortcuts;
        QVERIFY(!shortcuts.captureAllowed()); // Unknown lock state blocks Pi requests too.
        QTRY_COMPARE(desktop.lockReads, 1);
        QTRY_VERIFY(shortcuts.captureAllowed());
        QVERIFY(desktop.methods.isEmpty());
        QVERIFY(!shortcuts.enabled());
        QVERIFY(!shortcuts.busy());
    }
    void keysAreSessionScopedAndDuplicatePressesAreIgnored() {
        FakeDesktop desktop;
        QVERIFY(desktop.start());
        sotto::DesktopShortcuts shortcuts;
        QSignalSpy pressed(&shortcuts, &sotto::DesktopShortcuts::pressed);
        QSignalSpy released(&shortcuts, &sotto::DesktopShortcuts::released);
        shortcuts.setup();
        QTRY_VERIFY(shortcuts.enabled());
        QCOMPARE(desktop.bindings.size(), 3);
        QCOMPARE(desktop.bindings.at(0).properties.value("preferred_trigger").toString(), "LOGO+grave");
        QCOMPARE(desktop.bindings.at(1).properties.value("preferred_trigger").toString(), "LOGO+ALT+d");
        QCOMPARE(desktop.bindings.at(2).properties.value("preferred_trigger").toString(), "LOGO+apostrophe");
        QCOMPARE(shortcuts.bindings().size(), 3);
        QCOMPARE(desktop.methods.first(), "Register");
        desktop.key("Activated", "hold", root + "/session/other/wrong");
        desktop.key("Activated", "hold");
        desktop.key("Activated", "hold");
        desktop.key("Deactivated", "hold");
        desktop.key("Deactivated", "hold");
        QTRY_COMPARE(released.count(), 1);
        QCOMPARE(pressed.count(), 1);
        QCOMPARE(pressed.first().first().toString(), "hold");
    }
    void lockAndSessionLossCancelCaptureAndDoNotRestartIt() {
        FakeDesktop desktop;
        QVERIFY(desktop.start());
        sotto::DesktopShortcuts shortcuts;
        QSignalSpy pressed(&shortcuts, &sotto::DesktopShortcuts::pressed);
        QSignalSpy stop(&shortcuts, &sotto::DesktopShortcuts::captureMustStop);
        shortcuts.setup();
        QTRY_VERIFY(shortcuts.enabled());
        stop.clear();
        desktop.key("Activated", "hold");
        QTRY_COMPARE(pressed.count(), 1);
        desktop.lock(true);
        QTRY_COMPARE(stop.count(), 1);
        QVERIFY(!shortcuts.captureAllowed());
        desktop.key("Activated", "toggle");
        desktop.key("Deactivated", "hold");
        desktop.lock(false);
        desktop.key("Activated", "toggle");
        QTRY_COMPARE(pressed.count(), 2);
        QVERIFY(shortcuts.captureAllowed());
        desktop.closeSession();
        QTRY_VERIFY(!shortcuts.enabled());
        QCOMPARE(stop.count(), 2);
        QVERIFY(!shortcuts.busy());
        QCOMPARE(desktop.methods.count("CreateSession"), 1);
    }
    void declinedPermissionDoesNotEnableShortcuts() {
        FakeDesktop desktop;
        desktop.bindResponse = 1;
        QVERIFY(desktop.start());
        sotto::DesktopShortcuts shortcuts;
        shortcuts.setup();
        QTRY_VERIFY(!shortcuts.busy());
        QVERIFY(!shortcuts.enabled());
        QVERIFY(shortcuts.status().contains("cancelled"));
        QTRY_VERIFY(desktop.methods.contains("Close"));
    }
    void portalExitDoesNotAutomaticallyRequestPermissionAgain() {
        FakeDesktop desktop;
        QVERIFY(desktop.start());
        sotto::DesktopShortcuts shortcuts;
        shortcuts.setup();
        QTRY_VERIFY(shortcuts.enabled());
        QVERIFY(desktop.bus.unregisterService(portal));
        QTRY_VERIFY(!shortcuts.enabled());
        QVERIFY(shortcuts.status().contains("portal stopped"));
        QCOMPARE(desktop.methods.count("CreateSession"), 1);
    }
    void latePermissionResponseCannotReviveDisconnectedSession() {
        FakeDesktop desktop;
        desktop.holdBinding = true;
        QVERIFY(desktop.start());
        sotto::DesktopShortcuts shortcuts;
        shortcuts.setup();
        QTRY_VERIFY(desktop.methods.contains("BindShortcuts"));
        shortcuts.disconnectShortcuts();
        desktop.finishBinding();
        QTRY_VERIFY(desktop.methods.contains("Close"));
        QVERIFY(!shortcuts.enabled());
        QVERIFY(!shortcuts.busy());
        QVERIFY(shortcuts.status().contains("disconnected"));
    }
};

QTEST_GUILESS_MAIN(ShortcutTests)
#include "ShortcutTests.moc"
