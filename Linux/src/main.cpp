#include "CaptureController.h"
#include "DictationController.h"
#include "DesktopShortcuts.h"
#include "DesktopPaste.h"
#include "ServerStatus.h"
#include "PiDictationBridge.h"
#include "PersonalDictionary.h"
#include "RecordingStatus.h"
#include "TrayController.h"
#include <sys/stat.h>

#include <QCommandLineParser>
#include <QDir>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusVariant>
#include <QFileInfo>
#include <QApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMediaDevices>
#include <QLoggingCategory>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QTextStream>
#include <QTimer>

Q_LOGGING_CATEGORY(shortcutLog, "sotto.shortcuts", QtWarningMsg)

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    app.setQuitOnLastWindowClosed(false);
    // Keep the existing QSettings namespace and portal identity; branding must
    // not silently reset microphone preferences, device IDs, or permissions.
    QCoreApplication::setOrganizationName("Sotto");
    QCoreApplication::setApplicationName("Sotto Linux Dev");
    QCoreApplication::setApplicationVersion("0.1.0");
    QGuiApplication::setDesktopFileName("org.sotto.Sotto.Dev");
    QGuiApplication::setApplicationDisplayName("cotto");

    QCommandLineParser parser;
    parser.setApplicationDescription("cotto Linux desktop client — development build");
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addOption({"list-inputs", "List actual Qt audio inputs without opening a microphone."});
    parser.addOption({"desktop-capabilities", "Read portal capabilities without requesting any permission."});
    parser.addOption({"server", "Local inference server URL.", "url", "http://127.0.0.1:8392"});
    parser.addOption({"input-name", "Select a microphone by its exact displayed name.", "name"});
    parser.addOption({"setup-shortcuts", "Open KDE global shortcut setup (requires user approval)."});
    parser.addOption({"screenshot", "Render the window to a PNG and exit without recording.", "path"});
    parser.addOption({"global-dictation", "Request keyboard-only paste permission and set up global dictation shortcuts (requires user approval)."});
    parser.addOption({"pi-dictation", "Enable explicit Pi-owned dictation over a private local socket (opt-in)."});
    parser.addOption({"pi-socket", "Override the Pi dictation socket inside an existing private directory.", "path"});
    parser.process(app);

    if (parser.isSet("desktop-capabilities")) {
        const auto property = [](const QString &interface, const QString &name) -> QJsonValue {
            auto request = QDBusMessage::createMethodCall("org.freedesktop.portal.Desktop",
                "/org/freedesktop/portal/desktop", "org.freedesktop.DBus.Properties", "Get");
            request.setArguments({interface, name});
            const auto reply = QDBusConnection::sessionBus().call(request, QDBus::Block, 3000);
            if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().size() != 1) return {};
            return QJsonValue::fromVariant(qvariant_cast<QDBusVariant>(reply.arguments().first()).variant());
        };
        const QJsonObject capabilities{
            {"platform", QGuiApplication::platformName()},
            {"desktop", qEnvironmentVariable("XDG_CURRENT_DESKTOP")},
            {"globalShortcutsVersion", property("org.freedesktop.portal.GlobalShortcuts", "version")},
            {"remoteDesktopVersion", property("org.freedesktop.portal.RemoteDesktop", "version")},
            {"remoteDesktopDeviceTypes", property("org.freedesktop.portal.RemoteDesktop", "AvailableDeviceTypes")},
            {"permissionsRequested", false},
        };
        QTextStream(stdout) << QJsonDocument(capabilities).toJson();
        return 0;
    }

    if (parser.isSet("list-inputs")) {
        QJsonArray inputs;
        for (const auto &device : QMediaDevices::audioInputs()) {
            const auto format = device.preferredFormat();
            inputs.append(QJsonObject{{"id", QString::fromLatin1(device.id().toHex())},
                {"name", device.description()}, {"default", device.isDefault()},
                {"sampleRate", format.sampleRate()}, {"channels", format.channelCount()},
                {"sampleFormat", static_cast<int>(format.sampleFormat())}});
        }
        QTextStream(stdout) << QJsonDocument(inputs).toJson();
        return 0;
    }

    sotto::CaptureController capture;
    if (parser.isSet("input-name")) {
        bool found = false;
        for (const auto &device : QMediaDevices::audioInputs()) {
            if (device.description() == parser.value("input-name")) {
                capture.setSelectedDevice(QString::fromLatin1(device.id().toHex()));
                found = true;
                break;
            }
        }
        if (!found) { QTextStream(stderr) << "The selected microphone was not found.\n"; return 1; }
    }
    sotto::ServerStatus server(QUrl(parser.value("server")));
    sotto::DesktopPaste paste;
    sotto::PersonalDictionary dictionary;
    sotto::DictationController dictation(capture, QUrl(parser.value("server")), paste);
    sotto::DesktopShortcuts shortcuts;
    const bool global = parser.isSet("global-dictation") && !parser.isSet("screenshot");
    sotto::PiDictationBridge piBridge;
    if (parser.isSet("pi-dictation") && !parser.isSet("screenshot")) {
        QString path = parser.value("pi-socket");
        if (path.isEmpty()) {
            const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
            if (runtime.isEmpty()) { QTextStream(stderr) << "Pi dictation needs XDG_RUNTIME_DIR.\n"; return 1; }
            const auto directory = runtime + "/sotto-dictation";
            ::mkdir(QFile::encodeName(directory).constData(), 0700);
            path = directory + "/input.sock";
        }
        if (!piBridge.listen(path)) { QTextStream(stderr) << piBridge.errorString() << '\n'; return 1; }
        QObject::connect(&piBridge, &sotto::PiDictationBridge::startRequested, &app, [&](const QString &id) {
            if (!shortcuts.captureAllowed() || !dictation.startOwned(id))
                piBridge.reject(id, QStringLiteral("cotto is busy or the desktop is locked."));
        });
        QObject::connect(&piBridge, &sotto::PiDictationBridge::stopRequested, &dictation, &sotto::DictationController::stopOwned);
        QObject::connect(&piBridge, &sotto::PiDictationBridge::cancelRequested, &dictation, &sotto::DictationController::cancelOwned);
        QObject::connect(&piBridge, &sotto::PiDictationBridge::receipt, &dictation, &sotto::DictationController::deliveryReceipt);
        QObject::connect(&dictation, &sotto::DictationController::ownedRecording, &piBridge, &sotto::PiDictationBridge::recording);
        QObject::connect(&dictation, &sotto::DictationController::ownedProcessing, &piBridge, &sotto::PiDictationBridge::processing);
        QObject::connect(&dictation, &sotto::DictationController::ownedAborted, &piBridge, &sotto::PiDictationBridge::reject);
        QObject::connect(&dictation, &sotto::DictationController::ownedTranscript, &app, [&](const QString &id, const QString &text) {
            if (shortcuts.captureAllowed()) piBridge.complete(id, text);
            else piBridge.reject(id, QStringLiteral("Desktop locked before delivery. Review the transcript in cotto."));
        });
    }
    sotto::RecordingStatus recordingStatus;
    if (!parser.isSet("screenshot") && (global || parser.isSet("pi-dictation"))) {
        const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
        if (!runtime.isEmpty() && recordingStatus.open(runtime + "/cotto-status")) {
            QObject::connect(&capture, &sotto::CaptureController::stateChanged, &recordingStatus, [&] {
                recordingStatus.setRecording(capture.recording() && !capture.testing());
            });
            QObject::connect(&app, &QCoreApplication::aboutToQuit, &recordingStatus, [&] {
                recordingStatus.setRecording(false);
            });
        } else QTextStream(stderr) << "Recording status is unavailable; dictation remains independent.\n";
    }
    QObject::connect(&shortcuts, &sotto::DesktopShortcuts::changed, &app, [&shortcuts] {
        qCInfo(shortcutLog).noquote() << shortcuts.status();
    });
    QObject::connect(&shortcuts, &sotto::DesktopShortcuts::pressed, &app, [](const QString &id) {
        qCInfo(shortcutLog).noquote() << "Pressed:" << id;
    });
    QObject::connect(&shortcuts, &sotto::DesktopShortcuts::released, &app, [](const QString &id) {
        qCInfo(shortcutLog).noquote() << "Released:" << id;
    });
    QObject::connect(&shortcuts, &sotto::DesktopShortcuts::pressed, &dictation, &sotto::DictationController::shortcutPressed);
    QObject::connect(&shortcuts, &sotto::DesktopShortcuts::released, &dictation, &sotto::DictationController::shortcutReleased);
    QObject::connect(&shortcuts, &sotto::DesktopShortcuts::captureMustStop, &dictation, &sotto::DictationController::cancel);
    sotto::TrayController tray;
    QQmlApplicationEngine engine;
    engine.setInitialProperties({{"windowController", QVariant::fromValue(&tray)},
                                 {"captureController", QVariant::fromValue(&capture)},
                                 {"dictionaryController", QVariant::fromValue(&dictionary)},
                                 {"dictationController", QVariant::fromValue(&dictation)},
                                 {"shortcutsController", QVariant::fromValue(&shortcuts)},
                                 {"pasteController", QVariant::fromValue(&paste)},
                                 {"serverStatus", QVariant::fromValue(&server)}});
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("SottoLinux", "Main");
    if (engine.rootObjects().isEmpty()) return 1;
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    if (!window) return 1;
    QObject::connect(&tray, &sotto::TrayController::showRequested, window, [window] {
        window->show();
        window->raise();
        window->requestActivate();
    });

    if (parser.isSet("screenshot")) {
        const auto destination = QFileInfo(parser.value("screenshot")).absoluteFilePath();
        QTimer::singleShot(800, &app, [&engine, destination] {
            auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
            const bool saved = window && window->grabWindow().save(destination);
            QTextStream(saved ? stdout : stderr) << (saved ? "Saved " : "Could not save ") << destination << '\n';
            QCoreApplication::exit(saved ? 0 : 1);
        });
    } else {
        if (!tray.start()) {
            QTextStream(stderr) << "Cannot register cotto's desktop activation service. Another instance may be running.\n";
            return 1;
        }
        QTimer::singleShot(0, &server, &sotto::ServerStatus::refresh);
        if (global) {
            QObject::connect(&paste, &sotto::DesktopPaste::changed, &shortcuts, [&, once = true]() mutable {
                if (once && paste.ready()) { once = false; shortcuts.setup(); }
            });
            QTimer::singleShot(0, &paste, &sotto::DesktopPaste::setup);
        } else if (parser.isSet("setup-shortcuts")) QTimer::singleShot(0, &shortcuts, &sotto::DesktopShortcuts::setup);
    }
    return app.exec();
}
