#include "PersonalDictionary.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSaveFile>
#include <QSet>
#include <QStandardPaths>

namespace sotto {
namespace {
QString validate(const QString &text, QStringList &words) {
    if (text.toUtf8().size() > 16384) return QStringLiteral("Words must fit within 16 KB.");
    QSet<QString> seen;
    for (const auto &line : text.split('\n')) {
        const auto word = line.trimmed().normalized(QString::NormalizationForm_C);
        if (word.isEmpty()) continue;
        if (word.size() > 128) return QStringLiteral("Each word or phrase must be at most 128 characters.");
        for (const auto character : word) {
            if (character.category() == QChar::Other_Control || character.category() == QChar::Other_Format
                || character.category() == QChar::Separator_Line || character.category() == QChar::Separator_Paragraph)
                return QStringLiteral("Words cannot contain hidden control characters.");
        }
        const auto key = word.toCaseFolded();
        if (seen.contains(key)) return QStringLiteral("Remove the duplicate word: %1").arg(word);
        seen.insert(key); words.append(word);
    }
    if (words.size() > 500) return QStringLiteral("Keep at most 500 words or phrases.");
    return {};
}
}
QString PersonalDictionary::defaultPath() {
    return QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation) + "/dictionary.json";
}
PersonalDictionary::PersonalDictionary(QObject *parent, QString path)
    : QObject(parent), m_path(path.isEmpty() ? defaultPath() : std::move(path)) {
    QFile file(m_path);
    if (!QFileInfo::exists(m_path)) return;
    const QFileInfo info(m_path);
    if (!info.isFile() || info.isSymLink() || !file.open(QIODevice::ReadOnly) || file.size() > 128 * 1024) {
        m_error = QStringLiteral("Cannot read your dictionary. Check its file permissions or save a replacement."); return;
    }
    const auto document = QJsonDocument::fromJson(file.read(128 * 1024 + 1));
    const auto object = document.object();
    if (!document.isObject() || object.size() != 2 || object.value("version").toInt() != 1 || !object.value("words").isArray()) {
        m_error = QStringLiteral("Your dictionary file is invalid. Save a replacement to continue."); return;
    }
    QStringList words;
    for (const auto &value : object.value("words").toArray()) {
        if (!value.isString() || value.toString().contains('\n')) {
            m_error = QStringLiteral("Your dictionary contains an invalid word."); return;
        }
        words.append(value.toString());
    }
    QStringList checked;
    m_error = validate(words.join('\n'), checked);
    if (m_error.isEmpty()) m_text = checked.join('\n');
}
bool PersonalDictionary::save(const QString &text) {
    QStringList words;
    m_error = validate(text, words);
    if (!m_error.isEmpty()) { emit changed(); return false; }
    const QFileInfo existing(m_path);
    if (existing.isSymLink() || (existing.exists() && !existing.isFile())) {
        m_error = QStringLiteral("Dictionary must be a regular file, not a link or directory.");
        emit changed(); return false;
    }
    QSaveFile file(m_path);
    const auto bytes = QJsonDocument(QJsonObject{{"version", 1}, {"words", QJsonArray::fromStringList(words)}}).toJson();
    if (!QDir().mkpath(QFileInfo(m_path).absolutePath()) || !file.open(QIODevice::WriteOnly)
        || !file.setPermissions(QFile::ReadOwner | QFile::WriteOwner)
        || file.write(bytes) != bytes.size() || !file.commit()) {
        m_error = QStringLiteral("Could not save your dictionary. Your saved words were not changed.");
        emit changed(); return false;
    }
    m_text = words.join('\n'); emit changed(); return true;
}
QJsonObject PersonalDictionary::snapshot() const {
    QJsonArray entries;
    int index = 0;
    for (const auto &word : m_text.split('\n', Qt::SkipEmptyParts))
        entries.append(QJsonObject{{"id", QString::number(++index)}, {"term", word},
            {"aliases", QJsonArray{}}, {"isPriority", false}});
    return {{"lists", QJsonArray{QJsonObject{{"id", "personal"}, {"name", "Personal"}, {"entries", entries}}}}};
}
}
