import Darwin
import Foundation
import SottoCore

struct TranscriptionResult: Sendable {
    let text: String
    let audioSeconds: Double
    let processingSeconds: Double
    let language: String
}

enum EngineError: LocalizedError {
    case unavailable(String)
    case cancelled
    case busy

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .cancelled: return "Dictation cancelled."
        case .busy: return "Sotto is already transcribing."
        }
    }
}

@MainActor
final class EngineClient {
    var onStatus: ((EngineStatus, String) -> Void)?
    var onProgress: ((Double) -> Void)?
    private(set) var status: EngineStatus = .unloaded
    private(set) var processIdentifier: Int32?
    private(set) var engineVersion: String?
    private let paths: SottoPaths
    private let helperURL: URL
    private let vadURL: URL
    private var process: Process?
    private var input: FileHandle?
    private var generation = UUID()
    private var loadingTask: Task<Void, Error>?
    private var loadingID: UUID?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var resultContinuation: CheckedContinuation<TranscriptionResult, Error>?
    private var requestID: String?
    private var timeoutTask: Task<Void, Never>?
    private var lastDiagnostic = ""

    init(paths: SottoPaths = SottoPaths(), helperURL: URL? = nil, vadURL: URL? = nil) {
        self.paths = paths
        if let helperURL {
            self.helperURL = helperURL
        } else if let override = ProcessInfo.processInfo.environment["SOTTO_ENGINE_PATH"]
            ?? ProcessInfo.processInfo.environment["MURMUR_ENGINE_PATH"] {
            self.helperURL = URL(fileURLWithPath: override)
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            self.helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sotto-engine")
        } else {
            self.helperURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/native/Engine/sotto-engine")
        }
        if let vadURL {
            self.vadURL = vadURL
        } else if let override = ProcessInfo.processInfo.environment["SOTTO_VAD_PATH"]
            ?? ProcessInfo.processInfo.environment["MURMUR_VAD_PATH"] {
            self.vadURL = URL(fileURLWithPath: override)
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            self.vadURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/silero-vad.bin")
        } else {
            self.vadURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/models/silero-vad.bin")
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

    func transcribe(_ audioURL: URL, language: String, prompt: String) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        try await ensureLoaded()
        try Task.checkCancellation()
        guard resultContinuation == nil else { throw EngineError.busy }
        guard let input, process?.isRunning == true else {
            throw EngineError.unavailable("The local engine stopped. Try dictating again.")
        }
        let id = UUID().uuidString
        let request: [String: Any] = [
            "type": "transcribe", "id": id, "path": audioURL.path,
            "language": language, "prompt": prompt,
        ]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        requestID = id
        update(.transcribing, "Turning speech into text…")
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
            setTimeout(seconds: 180, message: "Transcription took too long. The engine has been reset; please try again.")
            do {
                try input.write(contentsOf: data)
            } catch {
                fail("Couldn’t send audio to the local engine: \(error.localizedDescription)")
            }
        }
    }

    func unload(reason: String = "Memory released") {
        generation = UUID()
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
        ready?.resume(throwing: EngineError.cancelled)
        result?.resume(throwing: EngineError.cancelled)
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
    func cancelPendingWork() {
        if status != .ready, loadingTask != nil || status == .loading || status == .transcribing {
            unload(reason: "Cancelled; memory released")
        }
    }

    private func start() async throws {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw EngineError.unavailable("The native engine is missing. Rebuild Sotto with scripts/build-app.sh.")
        }
        guard FileManager.default.fileExists(atPath: paths.model.path) else {
            throw EngineError.unavailable("Download the speech model first.")
        }
        guard FileManager.default.fileExists(atPath: vadURL.path) else {
            throw EngineError.unavailable("The speech detector is missing. Rebuild Sotto with scripts/build-app.sh.")
        }
        let current = UUID()
        generation = current
        lastDiagnostic = ""
        update(.loading, "Waking up the local model…")
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--model", paths.model.path, "--vad-model", vadURL.path,
                             "--threads", String(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)))]
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
                self.fail("The local engine exited (\(process.terminationStatus)). Try again or reload the model.")
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
                setTimeout(seconds: 120, message: "The model didn’t finish loading. Try reloading it from the Model tab.")
            } catch {
                fail("Couldn’t launch the local engine: \(error.localizedDescription)")
            }
        }
    }

    private func readLines(_ handle: FileHandle, generation current: UUID, diagnostics: Bool) {
        DispatchQueue(label: "dev.davis.murmur.engine.\(diagnostics ? "stderr" : "stdout")", qos: .userInitiated).async { [weak self] in
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
                            if diagnostics {
                                self.lastDiagnostic = String(decoding: line.suffix(2_000), as: UTF8.self)
                            } else {
                                self.receive(line)
                            }
                        }
                    }
                    if buffer.count > 1_048_576 {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == current else { return }
                            self.fail("The local engine returned an invalid response.")
                        }
                        break
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.fail("The connection to the local engine was interrupted.")
                }
            }
        }
    }

    private func receive(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            fail("The local engine returned an unreadable response.")
            return
        }
        switch type {
        case "ready":
            engineVersion = object["engineVersion"] as? String
            timeoutTask?.cancel()
            timeoutTask = nil
            update(.ready, "Warm and ready")
            let continuation = readyContinuation
            readyContinuation = nil
            continuation?.resume()
        case "progress":
            guard object["id"] as? String == requestID else { return }
            onProgress?(object["value"] as? Double ?? 0)
        case "result":
            guard object["id"] as? String == requestID else { return }
            timeoutTask?.cancel()
            timeoutTask = nil
            requestID = nil
            let continuation = resultContinuation
            resultContinuation = nil
            update(.ready, "Warm and ready")
            continuation?.resume(returning: TranscriptionResult(
                text: object["text"] as? String ?? "",
                audioSeconds: object["duration"] as? Double ?? 0,
                processingSeconds: object["elapsed"] as? Double ?? 0,
                language: object["language"] as? String ?? "en"
            ))
        case "error":
            let message = object["message"] as? String ?? "The local engine couldn’t transcribe that audio."
            if let id = object["id"] as? String, id != requestID { return }
            fail(message)
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
            guard let self, self.generation == current else { return }
            self.fail(message)
        }
    }

    private func fail(_ message: String) {
        let error = EngineError.unavailable(message)
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
