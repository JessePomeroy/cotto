import Combine
import Darwin
import Foundation
import SottoCore

@MainActor
final class TextModelStore: ObservableObject {
    struct Snapshot {
        var status: ModelStatus = .missing
        var progress: Double = 0
        var bytes: Int64 = 0
        var error: String?
    }

    let paths: TextModelPaths
    var onChange: ((Snapshot) -> Void)?
    @Published private(set) var snapshot = Snapshot() {
        didSet { onChange?(snapshot) }
    }
    private let model: TextModel
    private let sessionConfiguration: () -> URLSessionConfiguration
    private var modelURL: URL { paths.models.appendingPathComponent(model.filename, isDirectory: true) }
    private var generation = UUID()
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadID: UUID?
    private var stagingURL: URL?
    private var transferTask: Task<Result<Void, Error>, Never>?
    private var inspectionTask: Task<Bool, Never>?

    init(paths: TextModelPaths = TextModelPaths(), model: TextModel = .qwen,
         sessionConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral }) {
        self.paths = paths
        self.model = model
        self.sessionConfiguration = sessionConfiguration
    }

    func inspect() {
        guard transferTask == nil else { return }
        _ = beginInspection()
    }

    func verifyInstalled() async -> Bool {
        if let inspectionTask { return await inspectionTask.value }
        guard transferTask == nil else { return false }
        return await beginInspection().value
    }

    @discardableResult
    private func beginInspection() -> Task<Bool, Never> {
        let current = UUID()
        generation = current
        inspectionTask?.cancel()
        inspectionTask = nil
        do { try validateModelPathIfPresent() }
        catch {
            snapshot = Snapshot(status: .failed, error: error.localizedDescription)
            return Task { false }
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            snapshot = Snapshot()
            return Task { false }
        }
        snapshot = Snapshot(status: .verifying)
        let modelURL = modelURL
        let model = model
        let task = Task {
            let work = Task.detached(priority: .utility) { model.verify(modelURL) }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard generation == current, !Task.isCancelled else { return false }
            inspectionTask = nil
            switch result {
            case .success:
                snapshot = Snapshot(status: .installed, progress: 1, bytes: model.byteCount)
                return true
            case .failure(let error):
                snapshot = Snapshot(status: .failed, error: error.localizedDescription)
                return false
            }
        }
        inspectionTask = task
        return task
    }

    func download() {
        guard transferTask == nil else { return }
        _ = startTransfer(source: nil)
    }

    /// Import a previously downloaded artifact without networking. HF cache
    /// symlinks are resolved only at the source; installed files are hard copies.
    func importVerified(from source: URL) async -> Result<Void, Error> {
        guard transferTask == nil else { return .failure(TextModelStorageError.busy) }
        let task = startTransfer(source: source)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func startTransfer(source: URL?) -> Task<Result<Void, Error>, Never> {
        let current = UUID()
        generation = current
        inspectionTask?.cancel()
        inspectionTask = nil
        let staging = paths.models.appendingPathComponent(".download-text-\(current.uuidString)", isDirectory: true)
        do {
            try preparePrivateDirectories()
            try validateModelPathIfPresent()
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            snapshot = Snapshot(status: .failed, error: error.localizedDescription)
            return Task { .failure(error) }
        }
        stagingURL = staging
        snapshot = Snapshot(status: source == nil ? .downloading : .verifying)
        let task = Task { () -> Result<Void, Error> in
            defer {
                if generation == current {
                    stagingURL = nil
                    transferTask = nil
                }
                // After a successful atomic swap this is the old model folder.
                // Cleanup never deletes the current installed model.
                try? FileManager.default.removeItem(at: staging)
            }
            do {
                try Task.checkCancellation()
                if let source {
                    let model = self.model
                    let work = Task.detached(priority: .utility) {
                        try Self.copyArtifact(model, from: source, to: staging)
                    }
                    try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                } else {
                    var completedBytes: Int64 = 0
                    for file in model.files {
                        try Task.checkCancellation()
                        try await downloadFile(file, to: staging.appendingPathComponent(file.filename),
                                               completedBytes: completedBytes, generation: current)
                        completedBytes += file.byteCount
                    }
                }
                guard generation == current else { throw CancellationError() }
                try Task.checkCancellation()
                snapshot = Snapshot(status: .verifying, progress: 1, bytes: model.byteCount)
                let model = self.model
                let work = Task.detached(priority: .utility) { model.verify(staging) }
                let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                try result.get()
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
                try installDirectory(staging)
                snapshot = Snapshot(status: .installed, progress: 1, bytes: model.byteCount)
                return .success(())
            } catch {
                if generation == current {
                    snapshot = Snapshot(status: .failed, error: error.localizedDescription)
                }
                return .failure(error)
            }
        }
        transferTask = task
        return task
    }

    private func downloadFile(_ file: TextModel.File, to destination: URL, completedBytes: Int64,
                              generation current: UUID) async throws {
        let requestID = UUID()
        downloadID = requestID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let delegate = TextModelDownloadDelegate(destination: destination, expectedBytes: file.byteCount) { [weak self] bytes in
                    Task { @MainActor in
                        guard let self, self.generation == current, self.downloadID == requestID,
                              self.snapshot.status == .downloading else { return }
                        let total = completedBytes + bytes
                        self.snapshot = Snapshot(status: .downloading,
                            progress: min(1, Double(total) / Double(self.model.byteCount)), bytes: total)
                    }
                } completion: { [weak self] result in
                    Task { @MainActor in
                        if let self, self.generation == current, self.downloadID == requestID {
                            self.downloadTask = nil
                            self.downloadID = nil
                            self.session?.finishTasksAndInvalidate()
                            self.session = nil
                        }
                        continuation.resume(with: result)
                    }
                }
                let configuration = sessionConfiguration()
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 3_600
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: file.downloadURL)
                downloadTask = task
                task.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.downloadID == requestID else { return }
                self.downloadTask?.cancel()
            }
        }
    }

    func cancelDownload() {
        stopOperations()
        snapshot = Snapshot()
        inspect()
    }

    func shutdown() { stopOperations() }

    func remove() -> Result<Void, Error> {
        stopOperations()
        do {
            try validateModelPathIfPresent()
            if FileManager.default.fileExists(atPath: modelURL.path) {
                try FileManager.default.removeItem(at: modelURL)
            }
            snapshot = Snapshot()
            return .success(())
        } catch {
            snapshot = Snapshot(status: .failed, error: error.localizedDescription)
            return .failure(error)
        }
    }

    private func stopOperations() {
        generation = UUID()
        inspectionTask?.cancel()
        inspectionTask = nil
        transferTask?.cancel()
        transferTask = nil
        downloadTask?.cancel()
        downloadTask = nil
        downloadID = nil
        session?.invalidateAndCancel()
        session = nil
        // The transfer's defer cleans up after any off-main file copying exits.
        // Removing the folder here could race a late URLSession callback.
        stagingURL = nil
    }

    private func installDirectory(_ staging: URL) throws {
        try preparePrivateDirectories()
        try validateModelPathIfPresent()
        let exists = FileManager.default.fileExists(atPath: modelURL.path)
        let flags = exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, modelURL.path, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func preparePrivateDirectories() throws {
        for directory in [paths.root, paths.models] {
            var info = stat()
            if lstat(directory.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                    throw TextModelStorageError.unsafePath
                }
            } else {
                guard errno == ENOENT else { throw TextModelStorageError.unsafePath }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    private func validateModelPathIfPresent() throws {
        for directory in [paths.root, paths.models, modelURL] {
            var info = stat()
            if lstat(directory.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                    throw TextModelStorageError.unsafePath
                }
            } else if errno != ENOENT { throw TextModelStorageError.unsafePath }
        }
    }

    private nonisolated static func copyArtifact(_ model: TextModel, from source: URL, to staging: URL) throws {
        for file in model.files {
            try Task.checkCancellation()
            let resolvedSource = source.appendingPathComponent(file.filename).resolvingSymlinksInPath()
            let sourceFD = open(resolvedSource.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard sourceFD >= 0 else { throw TextModelStorageError.unsafePath }
            let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
            defer { try? input.close() }
            var info = stat()
            guard fstat(sourceFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw TextModelStorageError.unsafePath }
            guard info.st_size == file.byteCount else { throw ModelIntegrityError.wrongSize(expected: file.byteCount, actual: info.st_size) }
            let target = staging.appendingPathComponent(file.filename)
            let targetFD = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard targetFD >= 0 else { throw TextModelStorageError.unsafePath }
            let output = FileHandle(fileDescriptor: targetFD, closeOnDealloc: true)
            defer { try? output.close() }
            var count: Int64 = 0
            while let data = try input.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                count += Int64(data.count)
                guard count <= file.byteCount else { throw ModelIntegrityError.wrongSize(expected: file.byteCount, actual: count) }
                try output.write(contentsOf: data)
            }
            guard count == file.byteCount else { throw ModelIntegrityError.wrongSize(expected: file.byteCount, actual: count) }
            try output.synchronize()
        }
    }
}

private final class TextModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let expectedBytes: Int64
    let progress: @Sendable (Int64) -> Void
    let completion: @Sendable (Result<Void, Error>) -> Void
    private let lock = NSLock()
    private var finished = false

    init(destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void,
         completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes {
            downloadTask.cancel()
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
            return
        }
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let shouldFinish = !finished
        finished = true
        lock.unlock()
        if shouldFinish { completion(result) }
    }
}

private enum TextModelStorageError: LocalizedError {
    case unsafePath
    case busy

    var errorDescription: String? {
        switch self {
        case .unsafePath: return "The text model must contain regular files in a private folder owned by your account."
        case .busy: return "The text model is already being downloaded or imported."
        }
    }
}
