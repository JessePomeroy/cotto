#pragma once

#include <QJsonObject>
#include <QObject>

namespace sotto {
// Per-OS-user storage. Never writes the server's shared preferences.
class PersonalDictionary : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString text READ text NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
public:
    explicit PersonalDictionary(QObject *parent = nullptr, QString path = {});
    QString text() const { return m_text; }
    QString error() const { return m_error; }
    QJsonObject snapshot() const;
    Q_INVOKABLE bool save(const QString &text);
    static QString defaultPath();
signals:
    void changed();
private:
    QString m_path, m_text, m_error;
};
}
