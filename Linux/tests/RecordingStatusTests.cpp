#include "RecordingStatus.h"
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QtTest>

class RecordingStatusTests : public QObject {
    Q_OBJECT
private slots:
    void onlyOnePublisherAndNoTranscript() {
        QTemporaryDir runtime;
        sotto::RecordingStatus publisher, competitor;
        const auto directory = runtime.filePath("cotto-status");
        QVERIFY(publisher.open(directory));
        QVERIFY(!competitor.open(directory));
        const auto read = [&] {
            QFile file(directory + "/recording.json");
            if (!file.open(QIODevice::ReadOnly)) return QJsonObject{};
            return QJsonDocument::fromJson(file.readAll()).object();
        };
        QCOMPARE(read().value("recording").toBool(true), false);
        publisher.setRecording(true);
        auto value = read();
        QCOMPARE(value.keys(), QStringList({"recording", "updatedAt", "v"}));
        QCOMPARE(value.value("recording").toBool(), true);
        const auto time = value.value("updatedAt").toInteger();
        QTRY_VERIFY(read().value("updatedAt").toInteger() > time);
        publisher.setRecording(false);
        QCOMPARE(read().value("recording").toBool(true), false);
        QVERIFY(!(QFile::permissions(directory + "/recording.json") & (QFile::ReadGroup | QFile::ReadOther)));
    }
};
QTEST_GUILESS_MAIN(RecordingStatusTests)
#include "RecordingStatusTests.moc"
