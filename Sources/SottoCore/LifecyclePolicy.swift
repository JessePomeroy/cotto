import Foundation

public enum LifecyclePolicy {
    public static let maximumRecordingSeconds: TimeInterval = 180

    /// Negative values mean keep warm until quit; zero means release as soon as work finishes.
    public static func unloadDelay(idleMinutes: Int) -> TimeInterval? {
        guard idleMinutes >= 0 else { return nil }
        return TimeInterval(idleMinutes * 60)
    }
}
