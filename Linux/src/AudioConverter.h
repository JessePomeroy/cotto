#pragma once

#include <QAudioFormat>
#include <QByteArray>
#include <QByteArrayView>
#include <QString>
#include <QVector>
#include <memory>
#include <samplerate.h>

namespace sotto {
struct ConvertedAudio {
    QByteArray original;
    QByteArray inference;
    QString error;
};

// Produces the two streams defined by Sotto's wire contract. The source format
// and selected channel stay fixed for one recording; finish drains filter delay.
class AudioConverter {
public:
    bool configure(const QAudioFormat &format, int channel, bool keepOriginal);
    ConvertedAudio consume(QByteArrayView bytes);
    ConvertedAudio finish();
private:
    ConvertedAudio convert(QByteArrayView bytes, bool final);
    QAudioFormat m_format;
    int m_channel = 0;
    bool m_keepOriginal = false;
    bool m_finished = true;
    QByteArray m_partial;
    QVector<float> m_mono;
    std::unique_ptr<SRC_STATE, decltype(&src_delete)> m_resampler{nullptr, src_delete};
};
} // namespace sotto
