import Combine
import Foundation
import SottoCore

/// High-frequency feedback is observed only by the waveform and clock leaves,
/// never forwarded through the dashboard's controller.
@MainActor
final class RecordingFeedback: ObservableObject {
    @Published private(set) var levels = Array(repeating: Float(0), count: 9)
    @Published private(set) var elapsedSeconds = 0

    func append(_ level: Float) {
        let sample = level.isFinite ? min(1, max(0, level)) : 0
        let next = Array(levels.dropFirst()) + [sample]
        // Old peaks still drain through the history; settled silence is free.
        if next != levels { levels = next }
    }

    func updateElapsed(_ elapsed: TimeInterval) {
        let bounded = elapsed.isFinite ? min(LifecyclePolicy.maximumRecordingSeconds, max(0, elapsed)) : 0
        let seconds = Int(bounded)
        if seconds != elapsedSeconds { elapsedSeconds = seconds }
    }

    func clearLevels() {
        let silence = Array(repeating: Float(0), count: 9)
        if levels != silence { levels = silence }
    }

    func reset() {
        clearLevels()
        if elapsedSeconds != 0 { elapsedSeconds = 0 }
    }
}
