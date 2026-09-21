#pragma once

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusObjectPath>
#include <QDBusMessage>
#include <QDBusServiceWatcher>
#include <QSet>
#include <QTimer>
#include <QVariantMap>
#include <functional>

namespace sotto {
struct PortalShortcut { QString id; QVariantMap properties; };
using PortalShortcuts = QList<PortalShortcut>;
QDBusArgument &operator<<(QDBusArgument &argument, const PortalShortcut &shortcut);
const QDBusArgument &operator>>(const QDBusArgument &argument, PortalShortcut &shortcut);

class DesktopShortcuts : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool enabled READ enabled NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
    Q_PROPERTY(QVariantList bindings READ bindings NOTIFY changed)
public:
    explicit DesktopShortcuts(QObject *parent = nullptr);
    ~DesktopShortcuts() override;
    bool busy() const { return m_busy; }
    bool enabled() const { return !m_bound.isEmpty(); }
    bool captureAllowed() const { return !m_locked && !m_sleeping; }
    QString status() const { return m_status; }
    QVariantList bindings() const { return m_bindings; }
    Q_INVOKABLE void setup();
    Q_INVOKABLE void disconnectShortcuts();
signals:
    void changed();
    void pressed(const QString &id);
    void released(const QString &id);
    void captureMustStop();
private slots:
    void response(uint response, const QVariantMap &results, const QDBusMessage &message);
    void activated(const QDBusObjectPath &session, const QString &id, qulonglong timestamp, const QVariantMap &options);
    void deactivated(const QDBusObjectPath &session, const QString &id, qulonglong timestamp, const QVariantMap &options);
    void shortcutsChanged(const QDBusObjectPath &session, const sotto::PortalShortcuts &shortcuts);
    void sessionClosed(const QVariantMap &details, const QDBusMessage &message);
    void lockChanged(bool locked);
    void sleepChanged(bool preparing);
private:
    using Result = std::function<void(const QVariantMap &)>;
    void request(const QString &method, QVariantList arguments, QVariantMap options, Result result);
    void createSession();
    void bindShortcuts();
    void updateBindings(const PortalShortcuts &shortcuts);
    void fail(const QString &message);
    void close();
    void refreshLockState();
    void clearRequest(bool cancel);
    QDBusConnection m_bus;
    QDBusServiceWatcher m_portalWatcher;
    QDBusServiceWatcher m_lockWatcher;
    QTimer m_timeout;
    QString m_session;
    QString m_request;
    QString m_status = QStringLiteral("Global shortcuts are not connected.");
    QVariantList m_bindings;
    QSet<QString> m_bound;
    QSet<QString> m_pressed;
    Result m_result;
    quint64 m_epoch = 0;
    quint64 m_lockEpoch = 0;
    quint64 m_portalEpoch = 0;
    bool m_busy = false;
    bool m_registered = false;
    bool m_locked = true;
    bool m_sleeping = false;
};
} // namespace sotto

Q_DECLARE_METATYPE(sotto::PortalShortcut)
Q_DECLARE_METATYPE(sotto::PortalShortcuts)
