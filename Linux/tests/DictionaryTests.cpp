#include "PersonalDictionary.h"
#include <QFile>
#include <QTemporaryDir>
#include <QtTest>

class DictionaryTests : public QObject {
    Q_OBJECT
private slots:
    void privatePersistentAndIndependent() {
        QTemporaryDir home;
        const auto path = home.filePath("user-a/dictionary.json");
        sotto::PersonalDictionary a(nullptr, path), b(nullptr, home.filePath("user-b/dictionary.json"));
        QVERIFY(a.text().isEmpty()); QVERIFY(a.save("Herdr\nSvelteKit"));
        sotto::PersonalDictionary reloaded(nullptr, path);
        QCOMPARE(reloaded.text(), "Herdr\nSvelteKit"); QVERIFY(b.text().isEmpty());
        const auto permissions = QFile::permissions(path);
        QVERIFY(!(permissions & (QFile::ReadGroup | QFile::WriteGroup | QFile::ReadOther | QFile::WriteOther)));
        QVERIFY(a.save(""));
        sotto::PersonalDictionary empty(nullptr, path); QVERIFY(empty.text().isEmpty());
    }
    void rejectedEditsKeepSavedWords() {
        QTemporaryDir home;
        sotto::PersonalDictionary dictionary(nullptr, home.filePath("words.json"));
        QVERIFY(dictionary.save("Herdr"));
        QVERIFY(!dictionary.save("Herdr\nherdr"));
        QVERIFY(!dictionary.save(QString("bad") + QChar(1)));
        QVERIFY(!dictionary.save(QString(129, 'a')));
        QCOMPARE(dictionary.text(), "Herdr");
        sotto::PersonalDictionary reloaded(nullptr, home.filePath("words.json"));
        QCOMPARE(reloaded.text(), "Herdr");
    }
    void malformedStorageDoesNotSilentlyBecomeAnEmptyDictionary() {
        QTemporaryDir home; const auto path = home.filePath("words.json");
        QFile file(path); QVERIFY(file.open(QIODevice::WriteOnly)); file.write("not json"); file.close();
        sotto::PersonalDictionary dictionary(nullptr, path);
        QVERIFY(!dictionary.error().isEmpty());
        QVERIFY(dictionary.save("Cotto")); QVERIFY(dictionary.error().isEmpty());
    }
};
QTEST_GUILESS_MAIN(DictionaryTests)
#include "DictionaryTests.moc"
