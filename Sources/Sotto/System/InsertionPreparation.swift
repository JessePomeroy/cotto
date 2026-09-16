import Foundation

enum InsertionPreparationRead<Value: Sendable>: Sendable {
    case ready(Value, capturedAt: TimeInterval)
    case unavailable
    case blocked(reason: String)
}

extension InsertionPreparationRead: Equatable where Value: Equatable {}

enum InsertionAccessibilityActivation: Equatable, Sendable {
    case supported
    case unsupported
    case blocked(reason: String)
}

struct InsertionPreparationEnvironment<Value: Sendable>: Sendable {
    var read: @Sendable () -> InsertionPreparationRead<Value>
    var activate: @Sendable () -> InsertionAccessibilityActivation
    var canWait: @Sendable () -> Bool
    var now: @Sendable () -> TimeInterval
    var pause: @Sendable (UInt64) async throws -> Void
}

/// Accessibility mode can precede the renderer's usable tree. Request it once,
/// then read focus without resetting Electron's two-second activation debounce.
enum InsertionPreparation {
    static let readinessSeconds: TimeInterval = 3
    static let pollingSeconds: TimeInterval = 0.1
    static let cancelled = "Dictation was cancelled. Nothing was pasted or copied."

    static func capture<Value>(using environment: InsertionPreparationEnvironment<Value>) async -> InsertionPreparationRead<Value> {
        guard !Task.isCancelled else { return .blocked(reason: cancelled) }
        let initial = environment.read()
        guard !Task.isCancelled else { return .blocked(reason: cancelled) }
        guard case .unavailable = initial else { return initial }
        guard environment.canWait() else { return .unavailable }

        let deadline = environment.now() + readinessSeconds
        let activation = environment.activate()
        guard !Task.isCancelled else { return .blocked(reason: cancelled) }
        switch activation {
        case .unsupported: return .unavailable
        case .blocked(let reason): return .blocked(reason: reason)
        case .supported: break
        }
        while true {
            guard !Task.isCancelled else { return .blocked(reason: cancelled) }
            guard environment.canWait(), environment.now() < deadline else { return .unavailable }
            let candidate = environment.read()
            guard !Task.isCancelled else { return .blocked(reason: cancelled) }
            switch candidate {
            case .ready(_, let capturedAt):
                // Slow safety reads may complete later; budget the actual
                // cursor capture, just as release checks budget that capture.
                return InsertionCapturePolicy.permitsInsertion(capturedAt: capturedAt, releasedAt: deadline) ? candidate : .unavailable
            case .blocked: return candidate
            case .unavailable: break
            }
            guard environment.canWait() else { return .unavailable }
            let remaining = deadline - environment.now()
            guard remaining > 0 else { return .unavailable }
            do {
                try await environment.pause(UInt64(min(pollingSeconds, remaining) * 1_000_000_000))
            } catch {
                return .blocked(reason: cancelled)
            }
        }
    }
}

/// Release stops only readiness retries. A field already captured before release
/// can finish its slower Paste-menu metadata discovery without being cancelled.
final class InsertionCaptureCutoff: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    var canWait: Bool { lock.withLock { !released } }

    func finish() { lock.withLock { released = true } }
}
