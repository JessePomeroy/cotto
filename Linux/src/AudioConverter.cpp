#include "AudioConverter.h"
#include "PcmSamples.h"

#include <QtEndian>
#include <algorithm>
#include <bit>
#include <cmath>

namespace sotto {
namespace {
void appendFloat(QByteArray &bytes, float value) {
    const auto word = qToLittleEndian(std::bit_cast<quint32>(value));
    bytes.append(reinterpret_cast<const char *>(&word), sizeof(word));
}
}

bool AudioConverter::configure(const QAudioFormat &format, int channel, bool keepOriginal) {
    m_finished = true;
    m_partial.clear();
    m_mono.clear();
    m_resampler.reset();
    if (!format.isValid() || format.sampleRate() < 8000 || format.sampleRate() > 192000
        || format.channelCount() > 8 || channel < 0 || channel >= format.channelCount()) return false;
    int error = 0;
    m_resampler.reset(src_new(SRC_SINC_FASTEST, 1, &error));
    if (!m_resampler || error) return false;
    m_format = format;
    m_channel = channel;
    m_keepOriginal = keepOriginal;
    m_finished = false;
    return true;
}

ConvertedAudio AudioConverter::consume(QByteArrayView bytes) { return convert(bytes, false); }
ConvertedAudio AudioConverter::finish() { return convert({}, true); }

ConvertedAudio AudioConverter::convert(QByteArrayView bytes, bool final) {
    ConvertedAudio result;
    if (m_finished || !m_resampler) {
        result.error = QStringLiteral("Audio conversion is not active.");
        return result;
    }
    if (bytes.size() > 1024 * 1024) {
        m_finished = true;
        result.error = QStringLiteral("The microphone supplied an oversized audio buffer.");
        return result;
    }
    QByteArray input = std::move(m_partial);
    input.append(bytes.data(), bytes.size());
    const auto frameBytes = m_format.bytesPerFrame();
    const auto frames = input.size() / frameBytes;
    const auto sampleBytes = m_format.bytesPerSample();
    for (qsizetype frame = 0; frame < frames; ++frame) {
        for (int channel = 0; channel < m_format.channelCount(); ++channel) {
            const auto offset = frame * frameBytes + channel * sampleBytes;
            const float value = normalizedSample(input.constData() + offset, m_format.sampleFormat());
            if (!std::isfinite(value)) {
                m_finished = true;
                return {{}, {}, QStringLiteral("The microphone returned non-finite audio samples.")};
            }
            if (m_keepOriginal) appendFloat(result.original, value);
            if (channel == m_channel) m_mono.append(value);
        }
    }
    m_partial = input.mid(frames * frameBytes);
    if (final && !m_partial.isEmpty()) {
        m_finished = true;
        return {{}, {}, QStringLiteral("Microphone audio ended with an incomplete frame.")};
    }
    const double ratio = 16000.0 / m_format.sampleRate();
    // Retain one input frame until finish, so end_of_input accompanies actual
    // data and the library can return its entire delayed filter tail.
    while (!m_mono.isEmpty()) {
        const auto count = final ? m_mono.size() : m_mono.size() - 1;
        if (count == 0) break;
        QVector<float> output(static_cast<qsizetype>(std::ceil(count * ratio)) + 512);
        SRC_DATA data{};
        data.data_in = m_mono.constData();
        data.data_out = output.data();
        data.input_frames = static_cast<long>(count);
        data.output_frames = static_cast<long>(output.size());
        data.src_ratio = ratio;
        data.end_of_input = final;
        const int error = src_process(m_resampler.get(), &data);
        if (error) {
            m_finished = true;
            return {{}, {}, QStringLiteral("Audio resampling failed: %1").arg(src_strerror(error))};
        }
        for (long i = 0; i < data.output_frames_gen; ++i) {
            appendFloat(result.inference, std::clamp(output[i], -1.0F, 1.0F));
        }
        m_mono.remove(0, data.input_frames_used);
        if (data.input_frames_used == 0 && data.output_frames_gen == 0) {
            m_finished = true;
            return {{}, {}, QStringLiteral("Audio resampling stopped making progress.")};
        }
    }
    if (final) m_finished = true;
    return result;
}
} // namespace sotto
