#pragma once

#include "PcmMeter.h"

#include <QAudioDevice>
#include <QAudioSource>
#include <QElapsedTimer>
#include <QMediaDevices>
#include <QObject>
#include <QPointer>
#include <QSettings>
#include <QTimer>
#include <QVariantList>
#include <memory>

namespace sotto {

class CaptureController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList devices READ devices NOTIFY devicesChanged)
    Q_PROPERTY(QString selectedDevice READ selectedDevice WRITE setSelectedDevice NOTIFY selectionChanged)
    Q_PROPERTY(int selectedChannel READ selectedChannel WRITE setSelectedChannel NOTIFY selectionChanged)
    Q_PROPERTY(int channelCount READ channelCount NOTIFY selectionChanged)
    Q_PROPERTY(QString formatDescription READ formatDescription NOTIFY selectionChanged)
    Q_PROPERTY(bool recording READ recording NOTIFY stateChanged)
    Q_PROPERTY(bool testing READ testing NOTIFY stateChanged)
    Q_PROPERTY(QString status READ status NOTIFY stateChanged)
    Q_PROPERTY(double level READ level NOTIFY meterChanged)
    Q_PROPERTY(double elapsed READ elapsed NOTIFY meterChanged)
    Q_PROPERTY(qint64 frames READ frames NOTIFY meterChanged)

public:
    explicit CaptureController(QObject *parent = nullptr);
    ~CaptureController() override;
    QVariantList devices() const;
    QString selectedDevice() const { return m_selectedDevice; }
    int selectedChannel() const { return m_selectedChannel; }
    int channelCount() const;
    QString formatDescription() const;
    bool recording() const { return m_source != nullptr; }
    bool testing() const { return recording() && m_testMode; }
    QAudioFormat activeFormat() const { return m_activeFormat; }
    QString status() const { return m_status; }
    double level() const { return m_level; }
    double elapsed() const;
    qint64 frames() const { return m_frames; }
    void setSelectedDevice(const QString &id);
    void setSelectedChannel(int channel);
    Q_INVOKABLE void startTest();
    Q_INVOKABLE void stopTest();
    bool startDictation();

signals:
    void devicesChanged();
    void selectionChanged();
    void stateChanged();
    void meterChanged();
    void samplesReady(const QByteArray &bytes);
    void captureEnded(bool failed);

private:
    QAudioDevice selectedInput() const;
    void refreshDevices();
    void readSamples();
    void startCapture(bool test);
    void finish(const QString &message, bool failed = false);
    QMediaDevices m_mediaDevices;
    QSettings m_settings;
    QList<QAudioDevice> m_devices;
    QString m_selectedDevice;
    int m_selectedChannel = 0;
    QAudioDevice m_pinnedDevice;
    QAudioFormat m_activeFormat;
    std::unique_ptr<QAudioSource> m_source;
    QPointer<QIODevice> m_input;
    PcmMeter m_meter;
    QTimer m_timer;
    QElapsedTimer m_elapsed;
    quint64 m_epoch = 0;
    QString m_status = QStringLiteral("Microphone is closed.");
    double m_level = 0;
    double m_finalElapsed = 0;
    qint64 m_frames = 0;
    qint64 m_captureBytes = 0;
    bool m_testMode = true;
};
} // namespace sotto
