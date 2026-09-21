#pragma once

#include <QAudioFormat>
#include <cstring>

namespace sotto {
template<typename T> T sampleAt(const char *bytes) {
    T value;
    std::memcpy(&value, bytes, sizeof(value));
    return value;
}

inline float normalizedSample(const char *bytes, QAudioFormat::SampleFormat format) {
    switch (format) {
    case QAudioFormat::UInt8: return (sampleAt<quint8>(bytes) - 128) / 128.0F;
    case QAudioFormat::Int16: return sampleAt<qint16>(bytes) / 32768.0F;
    case QAudioFormat::Int32: return static_cast<float>(sampleAt<qint32>(bytes) / 2147483648.0);
    case QAudioFormat::Float: return sampleAt<float>(bytes);
    default: return 0;
    }
}
} // namespace sotto
