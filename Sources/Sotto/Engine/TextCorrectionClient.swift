import Combine
import Darwin
import Foundation
import SottoCore

struct TextCorrectionResult: Sendable {
    let text: String
    let processingSeconds: Double
}

enum TextCorrectionError: LocalizedError {
    case unavailable(String)
    case cancelled
    case busy

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .cancelled: return "Text correction cancelled."
        case .busy: return "Sotto is already correcting a transcript."
        }
    }
}

@MainActor
final class TextCorrectionClient: ObservableObject {
    var onStatus: ((EngineStatus, String) -> Void)?
    @Published private(set) var status: EngineStatus = .unloaded
    private(set) var processIdentifier: Int32?
    private(set) var engineVersion: String?
    private let modelURL: URL
    private let helperURL: URL
    private var process: Process?
    private var input: FileHandle?
    private var generation = UUID()
    private var loadingTask: Task<Void, Error>?
    private var loadingID: UUID?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var resultContinuation: CheckedContinuation<TextCorrectionResult, Error>?
    private var requestID: String?
    private var timeoutTask: Task<Void, Never>?
    private let loadTimeout: Double
    private let correctionTimeout: Double
    private var activeOperationID: UUID?

    init(modelURL: URL = TextModelPaths().model, helperURL: URL? = nil,
         loadTimeout: Double = 30, correctionTimeout: Double = 18) {
        self.modelURL = modelURL
        self.loadTimeout = loadTimeout
        self.correctionTimeout = correctionTimeout
        if let helperURL {
            self.helperURL = helperURL
        } else if let override = ProcessInfo.processInfo.environment["SOTTO_TEXT_ENGINE_PATH"]
            ?? ProcessInfo.processInfo.environment["MURMUR_TEXT_ENGINE_PATH"] {
            self.helperURL = URL(fileURLWithPath: override)
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            self.helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sotto-text-engine")
        } else {
            self.helperURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/text-native/sotto-text-engine")
        }
    }

    func ensureLoaded() async throws {
        try Task.checkCancellation()
        if process?.isRunning == true, status == .ready || status == .transcribing { return }
        if let loadingTask { return try await loadingTask.value }
        engineVersion = nil
        let id = UUID()
        loadingID = id
        let task = Task { try await self.start() }
        loadingTask = task
        defer {
            if loadingID == id {
                loadingTask = nil
                loadingID = nil
            }
        }
        try await task.value
    }

    func correct(_ text: String, terms: [String], language: String) async throws -> TextCorrectionResult {
        try Task.checkCancellation()
        guard activeOperationID == nil else { throw TextCorrectionError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 24 * 1024, !text.contains("\0"),
              terms.count <= 256, terms.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
              terms.reduce(0, { $0 + $1.utf8.count }) <= 16_384,
              !language.isEmpty, language.utf8.count <= 32, !language.contains("\0") else {
            throw TextCorrectionError.unavailable("The transcript or dictionary exceeds the local correction limit.")
        }
        let operationID = UUID()
        let id = UUID().uuidString
        let request: [String: Any] = [
            "type": "correct", "id": id, "text": text, "terms": terms, "language": language,
        ]
        var data = try JSONSerialization.data(withJSONObject: request)
        guard data.count <= 64 * 1024 else {
            throw TextCorrectionError.unavailable("The encoded transcript or dictionary exceeds the local correction limit.")
        }
        data.append(0x0A)
        activeOperationID = operationID
        defer { if activeOperationID == operationID { activeOperationID = nil } }
        return try await withTaskCancellationHandler {
            try await ensureLoaded()
            try Task.checkCancellation()
            guard let input, process?.isRunning == true else {
                throw TextCorrectionError.unavailable("The local text engine stopped. The original transcript is kept.")
            }
            requestID = id
            update(.transcribing, "Polishing your words…")
            return try await withCheckedThrowingContinuation { continuation in
                resultContinuation = continuation
                setTimeout(seconds: correctionTimeout, message: "Local correction took too long. The original transcript is kept.")
                do { try input.write(contentsOf: data) }
                catch { fail("Couldn’t send text to the local model: \(error.localizedDescription)") }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.activeOperationID == operationID else { return }
                self.cancelCurrentOperation()
            }
        }
    }

    func unload(reason: String = "Memory released") {
        generation = UUID()
        activeOperationID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let ready = readyContinuation
        readyContinuation = nil
        let result = resultContinuation
        resultContinuation = nil
        requestID = nil
        loadingTask?.cancel()
        loadingTask = nil
        loadingID = nil
        ready?.resume(throwing: TextCorrectionError.cancelled)
        result?.resume(throwing: TextCorrectionError.cancelled)
        try? input?.close()
        input = nil
        let oldProcess = process
        process = nil
        processIdentifier = nil
        if let oldProcess, oldProcess.isRunning {
            oldProcess.terminate()
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if oldProcess.isRunning { kill(oldProcess.processIdentifier, SIGKILL) }
            }
        }
        update(.unloaded, reason)
    }

    /// Cancelling a take need not discard an already warm, idle model. Active
    /// loading/inference still exits promptly and resolves its waiting callers.
    func cancelCurrentOperation() {
        if status != .ready, loadingTask != nil || status == .loading || status == .transcribing {
            unload(reason: "Cancelled; memory released")
        }
    }

    private func start() async throws {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw TextCorrectionError.unavailable("The local text engine is missing. Rebuild Sotto with scripts/build-app.sh.")
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw TextCorrectionError.unavailable("Download the text model from the Model tab first.")
        }
        let current = UUID()
        generation = current
        update(.loading, "Waking up the local text model…")
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--model", modelURL.path]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.qualityOfService = .userInitiated
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.fail("The local text engine exited (\(process.terminationStatus)). Try again or reload the model.")
            }
        }
        self.process = process
        input = stdin.fileHandleForWriting
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            do {
                try process.run()
                processIdentifier = process.processIdentifier
                readLines(stdout.fileHandleForReading, generation: current, diagnostics: false)
                readLines(stderr.fileHandleForReading, generation: current, diagnostics: true)
                setTimeout(seconds: loadTimeout, message: "The text model didn’t finish loading. The original transcript is kept.")
            } catch {
                fail("Couldn’t launch the local text engine: \(error.localizedDescription)")
            }
        }
    }

    private func readLines(_ handle: FileHandle, generation current: UUID, diagnostics: Bool) {
        DispatchQueue(label: "dev.davis.murmur.text-engine.\(diagnostics ? "stderr" : "stdout")", qos: .userInitiated).async { [weak self] in
            defer { try? handle.close() }
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 16_384)
            do {
                while true {
                    // FileHandle.read(upToCount:) can wait to fill its entire
                    // request on a pipe. POSIX read returns each available chunk,
                    // so the tiny ready/result lines reach us immediately.
                    let count = bytes.withUnsafeMutableBytes { storage in
                        Darwin.read(handle.fileDescriptor, storage.baseAddress, storage.count)
                    }
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    buffer.append(contentsOf: bytes.prefix(count))
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == current else { return }
                            if !diagnostics { self.receive(line) }
                        }
                    }
                    if buffer.count > 64 * 1024 {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == current else { return }
                            self.fail("The local text engine returned an invalid response.")
                        }
                        break
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.fail("The connection to the local text engine was interrupted.")
                }
            }
        }
    }

    private func receive(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            fail("The local text engine returned an unreadable response.")
            return
        }
        switch type {
        case "ready":
            guard readyContinuation != nil, status == .loading else { return }
            engineVersion = object["engineVersion"] as? String
            timeoutTask?.cancel()
            timeoutTask = nil
            update(.ready, "Warm and ready")
            let continuation = readyContinuation
            readyContinuation = nil
            continuation?.resume()
        case "result":
            guard object["id"] as? String == requestID else { return }
            timeoutTask?.cancel()
            timeoutTask = nil
            requestID = nil
            let continuation = resultContinuation
            resultContinuation = nil
            update(.ready, "Warm and ready")
            guard let text = object["text"] as? String, !text.isEmpty, text.utf8.count <= 24 * 1024,
                  let elapsed = object["elapsed"] as? Double, elapsed.isFinite, elapsed >= 0 else {
                continuation?.resume(throwing: TextCorrectionError.unavailable("The local text model returned an invalid correction."))
                return
            }
            continuation?.resume(returning: TextCorrectionResult(text: text, processingSeconds: elapsed))
        case "error":
            let message = object["message"] as? String ?? "The local text model couldn’t correct this transcript."
            if let id = object["id"] as? String {
                guard id == requestID, let continuation = resultContinuation else { return }
                timeoutTask?.cancel()
                timeoutTask = nil
                requestID = nil
                resultContinuation = nil
                update(.ready, "Warm and ready")
                continuation.resume(throwing: TextCorrectionError.unavailable(message))
            } else {
                fail(message)
            }
        default:
            break
        }
    }

    private func setTimeout(seconds: Double, message: String) {
        timeoutTask?.cancel()
        let current = generation
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.fail(message)
        }
    }

    private func fail(_ message: String) {
        let error = TextCorrectionError.unavailable(message)
        let ready = readyContinuation
        readyContinuation = nil
        let result = resultContinuation
        resultContinuation = nil
        unload(reason: message)
        update(.failed, message)
        ready?.resume(throwing: error)
        result?.resume(throwing: error)
    }

    private func update(_ status: EngineStatus, _ message: String) {
        self.status = status
        onStatus?(status, message)
    }
}
