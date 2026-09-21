#include "TrayController.h"

#include <QCoreApplication>
#include <QDBusConnection>
#include <QIcon>
#include <QPainter>
#include <QPixmap>
#include <QTimer>

namespace sotto {
namespace {
constexpr auto service = "org.sotto.Sotto.Dev";
constexpr auto objectPath = "/org/sotto/Sotto";
QIcon microphoneIcon() {
    QPixmap image(32, 32);
    image.fill(Qt::transparent);
    QPainter painter(&image);
    painter.setRenderHint(QPainter::Antialiasing);
    painter.setPen(QPen(QColor("#bd9daf"), 2.5));
    painter.drawRoundedRect(QRectF(12, 3, 8, 16), 4, 4);
    painter.drawArc(QRectF(7, 8, 18, 16), 180 * 16, 180 * 16);
    painter.drawLine(16, 24, 16, 29);
    painter.drawLine(11, 29, 21, 29);
    painter.end();
    return QIcon::fromTheme("audio-input-microphone", QIcon(image));
}
}

TrayController::TrayController(QObject *parent)
    : QObject(parent), m_icon(microphoneIcon()),
      m_watcher(QStringLiteral("org.kde.StatusNotifierWatcher"), QDBusConnection::sessionBus(),
                QDBusServiceWatcher::WatchForOwnerChange) {
    m_menu.setStyleSheet(QStringLiteral(
        "QMenu { background: #16121c; color: #f2e8ed; border: 1px solid #985961; border-radius: 0; }"
        "QMenu::item { padding: 6px 14px; }"
        "QMenu::item:selected { background: #5d2f38; }"));
    connect(m_menu.addAction(QStringLiteral("Open cotto")), &QAction::triggered, this, &TrayController::Show);
    m_menu.addSeparator();
    connect(m_menu.addAction(QStringLiteral("Quit cotto")), &QAction::triggered, this, &TrayController::quitRequested);
    m_icon.setContextMenu(&m_menu);
    m_icon.setToolTip(QStringLiteral("cotto"));
    connect(&m_icon, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason reason) {
        if (reason == QSystemTrayIcon::Trigger || reason == QSystemTrayIcon::DoubleClick) Show();
    });
    connect(&m_watcher, &QDBusServiceWatcher::serviceOwnerChanged, this, [this] {
        // Let Qt's platform tray notice the host change before QML reads it.
        QTimer::singleShot(0, this, &TrayController::availabilityChanged);
    });
}
TrayController::~TrayController() {
    if (m_started) {
        auto bus = QDBusConnection::sessionBus();
        bus.unregisterObject(QString::fromLatin1(objectPath));
        bus.unregisterService(QString::fromLatin1(service));
    }
}
bool TrayController::start() {
    if (m_started) return true;
    auto bus = QDBusConnection::sessionBus();
    if (!bus.registerService(QString::fromLatin1(service))) return false;
    if (!bus.registerObject(QString::fromLatin1(objectPath), this, QDBusConnection::ExportScriptableSlots)) {
        bus.unregisterService(QString::fromLatin1(service));
        return false;
    }
    m_started = true;
    // Qt automatically registers with a tray host that appears later.
    m_icon.show();
    emit availabilityChanged();
    return true;
}
bool TrayController::available() const {
    return m_started && QSystemTrayIcon::isSystemTrayAvailable();
}
void TrayController::Show() { emit showRequested(); }
void TrayController::finishQuit() { QCoreApplication::quit(); }
} // namespace sotto
