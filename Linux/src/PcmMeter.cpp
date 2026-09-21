#include "PcmMeter.h"
#include "PcmSamples.h"

#include <algorithm>
#include <cmath>

namespace sotto {

bool PcmMeter::configure(const QAudioFormat &format, int channel) {
    reset();
    if (!format.isValid() || channel < 0 || channel >= format.channelCount()) {
        m_format = {};
        return false;
    }
    m_format = format;
    m_channel = channel;
    return true;
}

void PcmMeter::reset() { m_remainder.clear(); }

MeterReading PcmMeter::consume(QByteArrayView bytes) {
    MeterReading result;
    if (!m_format.isValid()) return result;
    QByteArray data = std::move(m_remainder);
    data.append(bytes.data(), bytes.size());
    const auto frameBytes = m_format.bytesPerFrame();
    const auto sampleBytes = m_format.bytesPerSample();
    result.frames = data.size() / frameBytes;
    double squares = 0;
    for (qsizetype frame = 0; frame < result.frames; ++frame) {
        const auto offset = frame * frameBytes + m_channel * sampleBytes;
        float value = normalizedSample(data.constData() + offset, m_format.sampleFormat());
        if (!std::isfinite(value)) value = 0;
        value = std::clamp(value, -1.0F, 1.0F);
        result.peak = std::max(result.peak, std::abs(value));
        squares += static_cast<double>(value) * value;
    }
    if (result.frames) result.rms = static_cast<float>(std::sqrt(squares / result.frames));
    m_remainder = data.mid(result.frames * frameBytes);
    return result;
}
} // namespace sotto
