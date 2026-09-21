#pragma once

#include <QDBusServiceWatcher>
#include <QMenu>
#include <QObject>
#include <QSystemTrayIcon>

namespace sotto {
class TrayController : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.sotto.Sotto")
    Q_PROPERTY(bool available READ available NOTIFY availabilityChanged)
public:
    explicit TrayController(QObject *parent = nullptr);
    ~TrayController() override;
    bool start();
    bool available() const;
    Q_INVOKABLE void finishQuit();
public slots:
    Q_SCRIPTABLE void Show();
signals:
    void showRequested();
    void quitRequested();
    void availabilityChanged();
private:
    QMenu m_menu;
    QSystemTrayIcon m_icon;
    QDBusServiceWatcher m_watcher;
    bool m_started = false;
};
} // namespace sotto
