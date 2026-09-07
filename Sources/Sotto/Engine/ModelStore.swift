import Foundation
import SottoCore

@MainActor
final class ModelStore {
    struct Snapshot {
        var status: ModelStatus = .missing
        var progress: Double = 0
        var bytes: Int64 = 0
        var error: String?
    }

    let paths: SottoPaths
    var onChange: ((Snapshot) -> Void)?
    private(set) var snapshot = Snapshot() {
        didSet { onChange?(snapshot) }
    }
    private var generation = UUID()
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var stagingURL: URL?

    init(paths: SottoPaths = SottoPaths()) {
        self.paths = paths
        // A previous crash may have interrupted a verified-model installation.
        if let entries = try? FileManager.default.contentsOfDirectory(at: paths.models, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix(".download-") {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    func inspect() {
        guard downloadTask == nil else { return }
        let current = UUID()
        generation = current
        guard FileManager.default.fileExists(atPath: paths.model.path) else {
            snapshot = Snapshot()
            return
        }
        snapshot = Snapshot(status: .verifying)
        let modelURL = paths.model
        Task {
            let result = await Task.detached(priority: .utility) { ModelIntegrity.verify(modelURL) }.value
            guard generation == current else { return }
            switch result {
            case .success:
                snapshot = Snapshot(status: .installed, progress: 1, bytes: SpeechModel.turbo.byteCount)
            case .failure(let error):
                snapshot = Snapshot(status: .failed, error: error.localizedDescription)
            }
        }
    }

    func download() {
        guard downloadTask == nil, snapshot.status != .verifying else { return }
        let current = UUID()
        generation = current
        do {
            try FileManager.default.createDirectory(at: paths.models, withIntermediateDirectories: true)
        } catch {
            snapshot = Snapshot(status: .failed, error: error.localizedDescription)
            return
        }
        let staging = paths.models.appendingPathComponent(".download-\(current.uuidString)")
        stagingURL = staging
        snapshot = Snapshot(status: .downloading)
        let delegate = ModelDownloadDelegate(destination: staging) { [weak self] bytes in
            Task { @MainActor in
                guard let self, self.generation == current, self.snapshot.status == .downloading else { return }
                self.snapshot = Snapshot(status: .downloading,
                                         progress: min(1, Double(bytes) / Double(SpeechModel.turbo.byteCount)),
                                         bytes: bytes)
            }
        } completion: { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == current else {
                    if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.downloadTask = nil
                self.session?.finishTasksAndInvalidate()
                self.session = nil
                switch result {
                case .failure(let error):
                    self.snapshot = Snapshot(status: .failed, error: "Download failed: \(error.localizedDescription)")
                case .success(let url):
                    await self.install(url, generation: current)
                }
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: SpeechModel.turbo.downloadURL)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        generation = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
        if let stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
        stagingURL = nil
        snapshot = Snapshot()
        inspect()
    }

    func shutdown() {
        generation = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
        if let stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
        stagingURL = nil
    }

    func remove() -> Result<Void, Error> {
        cancelDownload()
        generation = UUID()
        do {
            if FileManager.default.fileExists(atPath: paths.model.path) {
                try FileManager.default.removeItem(at: paths.model)
            }
            snapshot = Snapshot()
            return .success(())
        } catch {
            snapshot = Snapshot(status: .failed, error: error.localizedDescription)
            return .failure(error)
        }
    }

    private func install(_ url: URL, generation current: UUID) async {
        snapshot = Snapshot(status: .verifying, progress: 1, bytes: SpeechModel.turbo.byteCount)
        let result = await Task.detached(priority: .utility) { ModelIntegrity.verify(url) }.value
        guard generation == current else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        switch result {
        case .failure(let error):
            try? FileManager.default.removeItem(at: url)
            snapshot = Snapshot(status: .failed, error: error.localizedDescription)
        case .success:
            do {
                if FileManager.default.fileExists(atPath: paths.model.path) {
                    _ = try FileManager.default.replaceItemAt(paths.model, withItemAt: url)
                } else {
                    try FileManager.default.moveItem(at: url, to: paths.model)
                }
                stagingURL = nil
                snapshot = Snapshot(status: .installed, progress: 1, bytes: SpeechModel.turbo.byteCount)
            } catch {
                try? FileManager.default.removeItem(at: url)
                stagingURL = nil
                snapshot = Snapshot(status: .failed, error: "Couldn’t install the model: \(error.localizedDescription)")
            }
        }
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64) -> Void
    let completion: @Sendable (Result<URL, Error>) -> Void
    private let lock = NSLock()
    private var finished = false

    init(destination: URL, progress: @escaping @Sendable (Int64) -> Void,
         completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.progress = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        do {
            // URLSession owns `location` only until this callback returns.
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let shouldFinish = !finished
        finished = true
        lock.unlock()
        if shouldFinish { completion(result) }
    }
}
