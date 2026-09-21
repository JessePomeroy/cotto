#include "DesktopShortcuts.h"

#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QUuid>
#include <utility>

namespace sotto {
namespace {
const QString service = QStringLiteral("org.freedesktop.portal.Desktop");
const QString root = QStringLiteral("/org/freedesktop/portal/desktop");
const QString interface = QStringLiteral("org.freedesktop.portal.GlobalShortcuts");
const QString requestInterface = QStringLiteral("org.freedesktop.portal.Request");
const QString sessionInterface = QStringLiteral("org.freedesktop.portal.Session");
QString token() { return "sotto_" + QUuid::createUuid().toString(QUuid::Id128); }
QString senderPath(const QDBusConnection &bus) { return bus.baseService().mid(1).replace('.', '_'); }
bool knownId(const QString &id) { return id == "hold" || id == "toggle" || id == "cancel"; }
void closeHandle(const QDBusConnection &bus, const QString &path, const QString &type) {
    auto call = QDBusMessage::createMethodCall(service, path, type, "Close");
    call.setAutoStartService(false);
    bus.asyncCall(call);
}
}

QDBusArgument &operator<<(QDBusArgument &argument, const PortalShortcut &shortcut) {
    argument.beginStructure(); argument << shortcut.id << shortcut.properties; argument.endStructure(); return argument;
}
const QDBusArgument &operator>>(const QDBusArgument &argument, PortalShortcut &shortcut) {
    argument.beginStructure(); argument >> shortcut.id >> shortcut.properties; argument.endStructure(); return argument;
}

DesktopShortcuts::DesktopShortcuts(QObject *parent)
    : QObject(parent), m_bus(QDBusConnection::connectToBus(QDBusConnection::SessionBus, token())),
      m_portalWatcher(service, m_bus, QDBusServiceWatcher::WatchForUnregistration, this),
      m_lockWatcher("org.freedesktop.ScreenSaver", m_bus, QDBusServiceWatcher::WatchForOwnerChange, this) {
    qDBusRegisterMetaType<PortalShortcut>();
    qDBusRegisterMetaType<PortalShortcuts>();
    m_timeout.setSingleShot(true);
    m_timeout.setInterval(120000);
    connect(&m_timeout, &QTimer::timeout, this, [this] { fail(QStringLiteral("Shortcut setup timed out. You can try again.")); });
    m_bus.connect(service, root, interface, "Activated", this,
        SLOT(activated(QDBusObjectPath,QString,qulonglong,QVariantMap)));
    m_bus.connect(service, root, interface, "Deactivated", this,
        SLOT(deactivated(QDBusObjectPath,QString,qulonglong,QVariantMap)));
    m_bus.connect(service, root, interface, "ShortcutsChanged", this,
        SLOT(shortcutsChanged(QDBusObjectPath,sotto::PortalShortcuts)));
    m_bus.connect("org.freedesktop.ScreenSaver", "/ScreenSaver", "org.freedesktop.ScreenSaver", "ActiveChanged",
        this, SLOT(lockChanged(bool)));
    QDBusConnection::systemBus().connect("org.freedesktop.login1", "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager", "PrepareForSleep", this, SLOT(sleepChanged(bool)));
    connect(&m_portalWatcher, &QDBusServiceWatcher::serviceUnregistered, this, [this] {
        ++m_portalEpoch;
        m_registered = false;
        fail(QStringLiteral("The desktop portal stopped. Reconnect shortcuts when it is available."));
    });
    connect(&m_lockWatcher, &QDBusServiceWatcher::serviceOwnerChanged, this,
        [this](const QString &, const QString &, const QString &) { lockChanged(true); refreshLockState(); });
    refreshLockState();
}

DesktopShortcuts::~DesktopShortcuts() { close(); QDBusConnection::disconnectFromBus(m_bus.name()); }

void DesktopShortcuts::setup() {
    if (m_busy) return;
    if (!m_session.isEmpty()) {
        auto call = QDBusMessage::createMethodCall(service, root, interface, "ConfigureShortcuts");
        call.setArguments({QVariant::fromValue(QDBusObjectPath(m_session)), QString{}, QVariantMap{}});
        auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(call), this);
        connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, watcher, epoch = m_epoch] {
            QDBusPendingReply<> reply = *watcher;
            watcher->deleteLater();
            if (epoch == m_epoch && reply.isError()) { m_status = "Could not open KDE shortcut configuration."; emit changed(); }
        });
        return;
    }
    m_busy = true;
    ++m_epoch;
    m_status = QStringLiteral("Preparing KDE shortcut setup…");
    emit changed();
    if (m_registered) { createSession(); return; }
    // Register this unsandboxed client explicitly, so shortcuts do not inherit
    // the identity of the terminal or IDE that launched the development binary.
    auto call = QDBusMessage::createMethodCall(service, root, "org.freedesktop.host.portal.Registry", "Register");
    call.setArguments({QStringLiteral("org.sotto.Sotto.Dev"), QVariantMap{}});
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(call), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, watcher, epoch = m_epoch, portalEpoch = m_portalEpoch] {
        QDBusPendingReply<> reply = *watcher;
        watcher->deleteLater();
        if (portalEpoch != m_portalEpoch) return;
        if (!reply.isError()) m_registered = true;
        if (epoch != m_epoch) return;
        if (reply.isError()) { fail(QStringLiteral("Could not register cotto's desktop identity: %1").arg(reply.error().message())); return; }
        createSession();
    });
}

void DesktopShortcuts::request(const QString &method, QVariantList arguments, QVariantMap options, Result result) {
    const auto handle = token();
    m_request = root + "/request/" + senderPath(m_bus) + '/' + handle;
    options.insert("handle_token", handle);
    m_result = std::move(result);
    if (!m_bus.connect(service, m_request, requestInterface, "Response", this, SLOT(response(uint,QVariantMap,QDBusMessage)))) {
        fail(QStringLiteral("Could not listen for the desktop permission response.")); return;
    }
    arguments.append(options);
    auto call = QDBusMessage::createMethodCall(service, root, interface, method);
    call.setArguments(arguments);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(call), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
        [this, watcher, epoch = m_epoch, expected = m_request] {
            QDBusPendingReply<QDBusObjectPath> reply = *watcher;
            watcher->deleteLater();
            if (epoch != m_epoch || m_request != expected) return;
            if (reply.isError()) fail(QStringLiteral("KDE shortcut setup failed: %1").arg(reply.error().message()));
            else if (reply.value().path() != expected) fail(QStringLiteral("The portal returned an unexpected permission request handle."));
        });
    m_timeout.start();
}

void DesktopShortcuts::response(uint code, const QVariantMap &results, const QDBusMessage &message) {
    if (message.path() != m_request || m_request.isEmpty()) return;
    auto result = std::move(m_result);
    clearRequest(false);
    if (code != 0) { fail(code == 1 ? QStringLiteral("Shortcut setup was cancelled.") : QStringLiteral("KDE did not grant shortcut access.")); return; }
    if (result) result(results);
}

void DesktopShortcuts::createSession() {
    const auto sessionToken = token();
    const auto expected = root + "/session/" + senderPath(m_bus) + '/' + sessionToken;
    request("CreateSession", {}, {{"session_handle_token", sessionToken}}, [this, expected](const QVariantMap &results) {
        if (results.value("session_handle").toString() != expected) { fail(QStringLiteral("The portal returned an invalid shortcut session.")); return; }
        m_session = expected;
        if (!m_bus.connect(service, m_session, sessionInterface, "Closed", this, SLOT(sessionClosed(QVariantMap,QDBusMessage)))) {
            fail(QStringLiteral("Could not monitor the shortcut session.")); return;
        }
        bindShortcuts();
    });
}

void DesktopShortcuts::bindShortcuts() {
    const PortalShortcuts shortcuts{
        {"hold", {{"description", "Hold to dictate"}, {"preferred_trigger", "LOGO+grave"}}},
        {"toggle", {{"description", "Start or stop dictation"}, {"preferred_trigger", "LOGO+ALT+d"}}},
        {"cancel", {{"description", "Cancel dictation"}, {"preferred_trigger", "LOGO+apostrophe"}}},
    };
    m_status = QStringLiteral("Choose shortcuts in the KDE dialog."); emit changed();
    request("BindShortcuts", {QVariant::fromValue(QDBusObjectPath(m_session)), QVariant::fromValue(shortcuts), QString{}}, {},
        [this](const QVariantMap &results) { m_busy = false; updateBindings(qdbus_cast<PortalShortcuts>(results.value("shortcuts"))); });
}

void DesktopShortcuts::updateBindings(const PortalShortcuts &shortcuts) {
    m_bound.clear(); m_bindings.clear(); m_pressed.clear();
    emit captureMustStop();
    for (const auto &shortcut : shortcuts) {
        if (!knownId(shortcut.id)) continue;
        const auto trigger = shortcut.properties.value("trigger_description").toString();
        if (trigger.isEmpty()) continue;
        m_bound.insert(shortcut.id);
        m_bindings.append(QVariantMap{{"id", shortcut.id}, {"name", shortcut.properties.value("description")}, {"trigger", trigger}});
    }
    m_status = enabled() ? QStringLiteral("Global shortcuts connected.") : QStringLiteral("No shortcuts are assigned. Open configuration to choose them.");
    emit changed();
}

void DesktopShortcuts::activated(const QDBusObjectPath &session, const QString &id, qulonglong, const QVariantMap &) {
    if (session.path() != m_session || !m_bound.contains(id) || m_pressed.contains(id) || m_locked || m_sleeping) return;
    m_pressed.insert(id); emit pressed(id);
}
void DesktopShortcuts::deactivated(const QDBusObjectPath &session, const QString &id, qulonglong, const QVariantMap &) {
    if (session.path() == m_session && m_pressed.remove(id)) emit released(id);
}
void DesktopShortcuts::shortcutsChanged(const QDBusObjectPath &session, const PortalShortcuts &shortcuts) {
    if (session.path() == m_session) updateBindings(shortcuts);
}
void DesktopShortcuts::sessionClosed(const QVariantMap &, const QDBusMessage &message) {
    if (!m_session.isEmpty() && message.path() == m_session) fail(QStringLiteral("KDE closed the shortcut session. Reconnect to use shortcuts."));
}

void DesktopShortcuts::clearRequest(bool cancel) {
    m_timeout.stop();
    if (!m_request.isEmpty()) {
        m_bus.disconnect(service, m_request, requestInterface, "Response", this, SLOT(response(uint,QVariantMap,QDBusMessage)));
        if (cancel) closeHandle(m_bus, m_request, requestInterface);
    }
    m_request.clear(); m_result = {};
}
void DesktopShortcuts::close() {
    ++m_epoch;
    clearRequest(true);
    if (!m_session.isEmpty()) {
        m_bus.disconnect(service, m_session, sessionInterface, "Closed", this, SLOT(sessionClosed(QVariantMap,QDBusMessage)));
        closeHandle(m_bus, m_session, sessionInterface);
    }
    m_session.clear(); m_bound.clear(); m_bindings.clear(); m_pressed.clear(); m_busy = false;
}
void DesktopShortcuts::fail(const QString &message) {
    close(); m_status = message; emit captureMustStop(); emit changed();
}
void DesktopShortcuts::disconnectShortcuts() { fail(QStringLiteral("Global shortcuts disconnected. Saved KDE assignments remain in desktop settings.")); }

void DesktopShortcuts::lockChanged(bool locked) {
    ++m_lockEpoch;
    m_locked = locked;
    if (locked) { m_pressed.clear(); emit captureMustStop(); }
}
void DesktopShortcuts::sleepChanged(bool preparing) {
    m_sleeping = preparing;
    if (preparing) { m_pressed.clear(); emit captureMustStop(); }
    else refreshLockState();
}
void DesktopShortcuts::refreshLockState() {
    m_locked = true;
    const auto epoch = ++m_lockEpoch;
    auto call = QDBusMessage::createMethodCall("org.freedesktop.ScreenSaver", "/ScreenSaver", "org.freedesktop.ScreenSaver", "GetActive");
    call.setAutoStartService(false);
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(call, 3000), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, watcher, epoch] {
        QDBusPendingReply<bool> reply = *watcher;
        watcher->deleteLater();
        if (epoch == m_lockEpoch && !reply.isError()) m_locked = reply.value();
    });
}
} // namespace sotto
