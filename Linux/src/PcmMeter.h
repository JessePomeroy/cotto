#pragma once

#include <QAudioFormat>
#include <QByteArray>
#include <QByteArrayView>

namespace sotto {

struct MeterReading {
    qsizetype frames = 0;
    float peak = 0;
    float rms = 0;
};

// Qt input buffers need not end at a frame boundary. Carry only the incomplete
// frame forward, and measure the chosen input without mixing unrelated channels.
class PcmMeter {
public:
    bool configure(const QAudioFormat &format, int channel);
    MeterReading consume(QByteArrayView bytes);
    void reset();

private:
    QAudioFormat m_format;
    int m_channel = 0;
    QByteArray m_remainder;
};

} // namespace sotto
