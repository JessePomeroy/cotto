#pragma once

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusServiceWatcher>
#include <QTimer>
#include <QProcess>
#include <QVariantMap>
#include <functional>

namespace sotto {
// Deliberately ordinary current-focus paste, not an original-field guarantee.
// Permission is explicit; only a fixed paste chord can be emitted.
class DesktopPaste : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready READ ready NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
public:
    explicit DesktopPaste(QObject *parent = nullptr, QString copyProgram = "wl-copy", QString readProgram = "wl-paste");
    ~DesktopPaste() override;
    bool ready() const { return m_ready; }
    bool busy() const { return m_setup || m_pasting; }
    QString status() const { return m_status; }
    Q_INVOKABLE void setup();
    Q_INVOKABLE void disconnectPaste();
    void paste(const QString &text);
    void cancel();
signals:
    void changed();
    void finished(const QString &receipt, const QString &message);
private slots:
    void response(uint code, const QVariantMap &results, const QDBusMessage &message);
    void sessionClosed(const QVariantMap &, const QDBusMessage &message);
private:
    void request(const QString &method, QVariantList arguments, QVariantMap options,
                 std::function<void(const QVariantMap &)> result);
    void createSession();
    void clearRequest(bool close);
    void close();
    void fail(const QString &message);
    void finish(const QString &message);
    void sendKey(int step);
    void verifyClipboard(int step);
    void releaseKeys();
    QDBusMessage keyCall(int key, uint state) const;
    QDBusConnection m_bus;
    QDBusServiceWatcher m_watcher;
    QTimer m_timeout, m_delay, m_clipboardTimeout;
    QProcess m_writer, m_reader;
    QString m_copyProgram, m_readProgram;
    QByteArray m_text, m_readback;
    QString m_request, m_session;
    int m_verifiedStep = 0;
    QString m_status = QStringLiteral("Automatic paste is off. Recordings remain available for Copy.");
    std::function<void(const QVariantMap &)> m_result;
    quint64 m_epoch = 0;
    bool m_registered = false;
    bool m_ready = false, m_setup = false, m_pasting = false, m_dispatched = false;
};
} // namespace sotto
