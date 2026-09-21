#include "CaptureController.h"

#include <algorithm>

namespace sotto {
namespace {
QString deviceId(const QAudioDevice &device) { return QString::fromLatin1(device.id().toHex()); }
}

CaptureController::CaptureController(QObject *parent) : QObject(parent) {
    m_selectedDevice = m_settings.value("microphone/device").toString();
    m_selectedChannel = std::max(0, m_settings.value("microphone/channel", 0).toInt());
    connect(&m_mediaDevices, &QMediaDevices::audioInputsChanged, this, &CaptureController::refreshDevices);
    m_timer.setInterval(50);
    connect(&m_timer, &QTimer::timeout, this, [this] {
        emit meterChanged();
        if (recording() && m_elapsed.elapsed() >= (m_testMode ? 10000 : 180000)) {
            readSamples();
            finish(m_testMode ? QStringLiteral("Test finished. Audio was measured and discarded.")
                              : QStringLiteral("Maximum recording duration reached."));
        }
    });
    refreshDevices();
}

CaptureController::~CaptureController() {
    if (m_source) {
        m_source->disconnect(this);
        m_source->stop();
    }
}

QVariantList CaptureController::devices() const {
    QVariantList result;
    result.append(QVariantMap{{"id", ""}, {"name", "Follow system default"}});
    bool selectedExists = m_selectedDevice.isEmpty();
    for (const auto &device : m_devices) {
        const auto id = deviceId(device);
        selectedExists |= id == m_selectedDevice;
        result.append(QVariantMap{{"id", id}, {"name", device.description()}});
    }
    if (!selectedExists) {
        result.append(QVariantMap{{"id", m_selectedDevice}, {"name", "Selected microphone (disconnected)"}});
    }
    return result;
}

QAudioDevice CaptureController::selectedInput() const {
    if (m_selectedDevice.isEmpty()) return QMediaDevices::defaultAudioInput();
    const auto found = std::find_if(m_devices.cbegin(), m_devices.cend(), [this](const auto &device) {
        return deviceId(device) == m_selectedDevice;
    });
    return found == m_devices.cend() ? QAudioDevice{} : *found;
}

int CaptureController::channelCount() const {
    if (recording()) return m_activeFormat.channelCount();
    const auto input = selectedInput();
    return input.isNull() ? 0 : input.preferredFormat().channelCount();
}

QString CaptureController::formatDescription() const {
    const auto input = recording() ? m_pinnedDevice : selectedInput();
    if (input.isNull()) return QStringLiteral("The selected input is unavailable.");
    const auto format = input.preferredFormat();
    return QStringLiteral("%1 · %2 Hz · %3 input channels")
        .arg(input.description()).arg(format.sampleRate()).arg(format.channelCount());
}

double CaptureController::elapsed() const {
    return recording() ? m_elapsed.elapsed() / 1000.0 : m_finalElapsed;
}

void CaptureController::setSelectedDevice(const QString &id) {
    if (recording() || id == m_selectedDevice) return;
    m_selectedDevice = id;
    m_selectedChannel = 0;
    m_settings.setValue("microphone/device", id);
    m_settings.setValue("microphone/channel", m_selectedChannel);
    emit selectionChanged();
}

void CaptureController::setSelectedChannel(int channel) {
    if (recording() || channel < 0 || channel >= channelCount() || channel == m_selectedChannel) return;
    m_selectedChannel = channel;
    m_settings.setValue("microphone/channel", channel);
    emit selectionChanged();
}

void CaptureController::refreshDevices() {
    m_devices = QMediaDevices::audioInputs();
    if (recording()) {
        const bool stillPresent = std::any_of(m_devices.cbegin(), m_devices.cend(), [this](const auto &device) {
            return device.id() == m_pinnedDevice.id();
        });
        if (!stillPresent) finish(QStringLiteral("Microphone disconnected. Capture stopped; no other input was opened."), true);
    }
    emit devicesChanged();
    emit selectionChanged();
}

void CaptureController::startTest() {
    startCapture(true);
}

bool CaptureController::startDictation() {
    if (recording()) return false;
    startCapture(false);
    return recording();
}

void CaptureController::startCapture(bool test) {
    if (recording()) return;
    const auto input = selectedInput();
    const auto format = input.preferredFormat();
    if (input.isNull() || !input.isFormatSupported(format) || !m_meter.configure(format, m_selectedChannel)) {
        m_status = QStringLiteral("Select an available microphone and input channel before testing.");
        emit stateChanged();
        return;
    }
    m_pinnedDevice = input;
    m_testMode = test;
    m_activeFormat = format;
    m_frames = 0;
    m_captureBytes = 0;
    m_level = 0;
    m_finalElapsed = 0;
    const auto epoch = ++m_epoch;
    m_source = std::make_unique<QAudioSource>(input, format);
    // Queue errors so a source is never destroyed from inside its own start/stop
    // callback. An event from an earlier source must not stop a newer recording.
    connect(m_source.get(), &QAudioSource::stateChanged, this, [this, epoch](QtAudio::State state) {
        if (epoch != m_epoch || !m_source) return;
        if (state == QtAudio::StoppedState && m_source->error() != QtAudio::NoError) {
            finish(QStringLiteral("Audio capture failed. The microphone was closed."), true);
        }
    }, Qt::QueuedConnection);
    m_elapsed.start();
    m_input = m_source->start();
    if (!m_input || m_source->error() != QtAudio::NoError) {
        finish(QStringLiteral("Could not open the selected microphone."), true);
        return;
    }
    connect(m_input, &QIODevice::readyRead, this, &CaptureController::readSamples);
    QTimer::singleShot(0, this, &CaptureController::readSamples);
    m_status = test ? QStringLiteral("Testing channel %1. Stops automatically after 10 seconds.").arg(m_selectedChannel + 1)
                    : QStringLiteral("Recording channel %1.").arg(m_selectedChannel + 1);
    m_timer.start();
    emit stateChanged();
    emit meterChanged();
    emit selectionChanged();
}

void CaptureController::readSamples() {
    if (!m_input || !m_source) return;
    // Bound each read even if the UI thread was briefly delayed.
    while (m_input && m_input->bytesAvailable() > 0) {
        const auto maximumBytes = qint64(m_activeFormat.sampleRate()) * m_activeFormat.bytesPerFrame()
            * (m_testMode ? 10 : 180);
        const auto bytes = m_input->read(std::min<qint64>(64 * 1024, maximumBytes - m_captureBytes));
        if (bytes.isEmpty()) break;
        m_captureBytes += bytes.size();
        const auto reading = m_meter.consume(bytes);
        m_frames += reading.frames;
        if (reading.frames) m_level = reading.peak;
        if (!m_testMode) emit samplesReady(bytes);
        if (recording() && m_captureBytes >= maximumBytes) {
            finish(m_testMode ? QStringLiteral("Test finished. Audio was measured and discarded.")
                              : QStringLiteral("Maximum recording duration reached."));
            return;
        }
    }
}

void CaptureController::finish(const QString &message, bool failed) {
    const bool dictation = recording() && !m_testMode;
    ++m_epoch;
    m_timer.stop();
    if (m_source) {
        m_finalElapsed = m_elapsed.elapsed() / 1000.0;
        if (m_input) m_input->disconnect(this);
        m_input.clear();
        m_source->disconnect(this);
        m_source->stop();
        m_source.reset();
    }
    m_level = 0;
    m_status = message;
    emit stateChanged();
    emit meterChanged();
    emit selectionChanged();
    if (dictation) emit captureEnded(failed);
}

void CaptureController::stopTest() {
    if (!recording()) return;
    readSamples();
    finish(m_testMode ? QStringLiteral("Test stopped. Audio was measured and discarded.")
                      : QStringLiteral("Microphone closed."));
}
} // namespace sotto
