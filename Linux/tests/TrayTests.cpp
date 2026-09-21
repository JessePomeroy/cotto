#include "TrayController.h"
#include <QApplication>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QSignalSpy>
#include <QTest>

class TrayTests : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        QVERIFY(qEnvironmentVariableIsSet("SOTTO_TEST_PRIVATE_BUS"));
    }
    void activationEndpointShowsButDoesNotQuit() {
        sotto::TrayController tray;
        QSignalSpy shown(&tray, &sotto::TrayController::showRequested);
        QSignalSpy quit(&tray, &sotto::TrayController::quitRequested);
        QVERIFY(tray.start());
        QVERIFY(tray.start());
        QVERIFY(!tray.available()); // The isolated bus deliberately has no tray host.
        auto message = QDBusMessage::createMethodCall("org.sotto.Sotto.Dev", "/org/sotto/Sotto", "org.sotto.Sotto", "Show");
        QDBusPendingCallWatcher call(QDBusConnection::sessionBus().asyncCall(message));
        QTRY_VERIFY(call.isFinished());
        QVERIFY(!call.isError());
        QCOMPARE(shown.count(), 1);
        QCOMPARE(quit.count(), 0);
        message.setArguments({"not accepted"});
        QDBusPendingCallWatcher malformed(QDBusConnection::sessionBus().asyncCall(message));
        QTRY_VERIFY(malformed.isFinished());
        QVERIFY(malformed.isError());
        QCOMPARE(shown.count(), 1);
    }
    void contextMenuSeparatesOpenAndQuit() {
        sotto::TrayController tray;
        QSignalSpy shown(&tray, &sotto::TrayController::showRequested);
        QSignalSpy quit(&tray, &sotto::TrayController::quitRequested);
        QMenu *menu = nullptr;
        for (auto *widget : QApplication::topLevelWidgets()) {
            auto *candidate = qobject_cast<QMenu *>(widget);
            if (candidate && candidate->actions().size() == 3
                && candidate->actions().first()->text() == "Open cotto") menu = candidate;
        }
        QVERIFY(menu);
        menu->actions().first()->trigger();
        QCOMPARE(shown.count(), 1); QCOMPARE(quit.count(), 0);
        menu->actions().last()->trigger();
        QCOMPARE(shown.count(), 1); QCOMPARE(quit.count(), 1);
    }
    void quittingIsNotExposedOverActivationBus() {
        sotto::TrayController tray;
        QVERIFY(tray.start());
        auto message = QDBusMessage::createMethodCall("org.sotto.Sotto.Dev", "/org/sotto/Sotto", "org.sotto.Sotto", "finishQuit");
        QDBusPendingCallWatcher call(QDBusConnection::sessionBus().asyncCall(message));
        QTRY_VERIFY(call.isFinished());
        QVERIFY(call.isError());
    }
};
QTEST_MAIN(TrayTests)
#include "TrayTests.moc"
