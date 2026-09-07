import Darwin
import Foundation

/// One completed take, not the contents of the destination app or a combined list.
public struct DictationArchiveRecord: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case hotkey, test, file }
    public enum Outcome: String, Codable, Sendable { case transcribed, noSpeech, failed }

    public struct Model: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let sha256: String
        public let engine: String
        public let engineVersion: String

        public init(id: String, name: String, sha256: String, engine: String, engineVersion: String) {
            self.id = id
            self.name = name
            self.sha256 = sha256
            self.engine = engine
            self.engineVersion = engineVersion
        }
    }

    public struct Options: Codable, Equatable, Sendable {
        public let requestedLanguage: String
        public let detectedLanguage: String?
        public let removeFillers: Bool
        public let vocabularyPrompt: String

        public init(requestedLanguage: String, detectedLanguage: String? = nil,
                    removeFillers: Bool, vocabularyPrompt: String) {
            self.requestedLanguage = requestedLanguage
            self.detectedLanguage = detectedLanguage
            self.removeFillers = removeFillers
            self.vocabularyPrompt = vocabularyPrompt
        }
    }

    public struct Microphone: Codable, Equatable, Sendable {
        public let uid: String?
        public let name: String?

        public init(uid: String?, name: String?) {
            self.uid = uid
            self.name = name
        }
    }

    public struct AudioFormat: Codable, Equatable, Sendable {
        public let sampleRate: Double
        public let channels: Int
        public let sampleFormat: String
        public let frameCount: Int64
        public let durationSeconds: Double

        public init(sampleRate: Double, channels: Int, sampleFormat: String,
                    frameCount: Int64, durationSeconds: Double) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.sampleFormat = sampleFormat
            self.frameCount = frameCount
            self.durationSeconds = durationSeconds
        }
    }

    public struct Audio: Codable, Equatable, Sendable {
        public let originalFilename: String
        public let transcriptionFilename: String
        public let original: AudioFormat
        public let transcription: AudioFormat

        public init(original: AudioFormat, transcription: AudioFormat) {
            originalFilename = "audio.wav"
            transcriptionFilename = "transcription.wav"
            self.original = original
            self.transcription = transcription
        }
    }

    public struct Timing: Codable, Equatable, Sendable {
        public let engineProcessingSeconds: Double?
        public let transcriptionWallSeconds: Double?
        public let releaseToResultSeconds: Double

        public init(engineProcessingSeconds: Double? = nil, transcriptionWallSeconds: Double? = nil,
                    releaseToResultSeconds: Double) {
            self.engineProcessingSeconds = engineProcessingSeconds
            self.transcriptionWallSeconds = transcriptionWallSeconds
            self.releaseToResultSeconds = releaseToResultSeconds
        }
    }

    public let schemaVersion: Int
    public let id: UUID
    public let startedAt: Date
    public let releasedAt: Date
    public let completedAt: Date
    public let mode: Mode
    public let outcome: Outcome
    public let rawText: String
    public let transcriptText: String
    public let model: Model
    public let options: Options
    public let microphone: Microphone
    public let audio: Audio
    public let timing: Timing
    public let appVersion: String
    public let appBuild: String?
    public let deliveryStatus: String?
    public let errorMessage: String?
    public let textProcessing: TextProcessingRecord?

    public init(id: UUID, startedAt: Date, releasedAt: Date, completedAt: Date,
                mode: Mode, outcome: Outcome, rawText: String, transcriptText: String,
                model: Model, options: Options, microphone: Microphone, audio: Audio,
                timing: Timing, appVersion: String, appBuild: String? = nil,
                deliveryStatus: String? = nil, errorMessage: String? = nil,
                textProcessing: TextProcessingRecord? = nil) {
        schemaVersion = 1
        self.id = id
        self.startedAt = startedAt
        self.releasedAt = releasedAt
        self.completedAt = completedAt
        self.mode = mode
        self.outcome = outcome
        self.rawText = rawText
        self.transcriptText = transcriptText
        self.model = model
        self.options = options
        self.microphone = microphone
        self.audio = audio
        self.timing = timing
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.deliveryStatus = deliveryStatus
        self.errorMessage = errorMessage
        self.textProcessing = textProcessing
    }
}

public enum DictationArchiveError: LocalizedError, Equatable, Sendable {
    case unsafePath(path: String, reason: String)
    case alreadyExists(path: String)
    case io(operation: String, path: String, detail: String)
    case invalidMetadata(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path, let reason):
            return "Local history cannot use \(path): \(reason)"
        case .alreadyExists(let path):
            return "A recording already exists at \(path). It was not overwritten."
        case .io(let operation, let path, let detail):
            return "Could not \(operation) at \(path): \(detail)"
        case .invalidMetadata(let detail):
            return "Could not encode the recording’s metadata: \(detail)"
        }
    }
}

/// An append-only local archive. The caller retains ownership of both source files.
/// All I/O runs on this actor, away from the UI actor. No retention policy or network access.
public actor DictationArchiveWriter {
    public nonisolated let root: URL
    public nonisolated let transcriptsDirectory: URL

    /// `root` must be a dedicated app directory; its parent must already exist.
    public init(root: URL? = nil) {
        self.root = (root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".murmur", isDirectory: true)).standardizedFileURL
        transcriptsDirectory = self.root.appendingPathComponent("transcripts", isDirectory: true)
    }

    public func prepare() -> Result<URL, DictationArchiveError> {
        do {
            let directory = try openArchive()
            close(directory)
            return .success(transcriptsDirectory)
        } catch let error as DictationArchiveError {
            return .failure(error)
        } catch {
            return .failure(.io(operation: "prepare local history", path: root.path,
                                detail: error.localizedDescription))
        }
    }

    public func save(record: DictationArchiveRecord, originalAudio: URL,
                     transcriptionAudio: URL) -> Result<URL, DictationArchiveError> {
        do {
            return .success(try write(record: record, originalAudio: originalAudio,
                                      transcriptionAudio: transcriptionAudio))
        } catch let error as DictationArchiveError {
            return .failure(error)
        } catch {
            return .failure(.io(operation: "save local history", path: transcriptsDirectory.path,
                                detail: error.localizedDescription))
        }
    }

    private func write(record: DictationArchiveRecord, originalAudio: URL, transcriptionAudio: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let isoDate = ISO8601DateFormatter()
            isoDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var value = encoder.singleValueContainer()
            try value.encode(isoDate.string(from: date))
        }
        let metadata: Data
        do { metadata = try encoder.encode(record) }
        catch { throw DictationArchiveError.invalidMetadata(error.localizedDescription) }

        let archive = try openArchive()
        defer { close(archive) }
        let day = Self.dateString(record.startedAt, format: "yyyy-MM-dd")
        let dayURL = transcriptsDirectory.appendingPathComponent(day, isDirectory: true)
        let dateDirectory = try Self.directory(day, in: archive, url: dayURL)
        defer { close(dateDirectory) }
        let name = Self.dateString(record.startedAt, format: "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'")
            + "-" + record.id.uuidString.lowercased()
        let finalURL = dayURL.appendingPathComponent(name, isDirectory: true)
        let stageName = ".pending-" + UUID().uuidString.lowercased()
        let stageURL = dayURL.appendingPathComponent(stageName, isDirectory: true)
        guard mkdirat(dateDirectory, stageName, mode_t(0o700)) == 0 else {
            throw Self.ioError("create a staging folder", stageURL)
        }
        let stage = openat(dateDirectory, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else {
            let error = Self.ioError("open a staging folder", stageURL)
            unlinkat(dateDirectory, stageName, AT_REMOVEDIR)
            throw error
        }
        var published = false
        defer {
            if !published {
                // Only remove known children of our open directory. Never traverse a replaced path.
                for filename in Self.filenames { unlinkat(stage, filename, 0) }
                unlinkat(dateDirectory, stageName, AT_REMOVEDIR)
            }
            close(stage)
        }

        try Self.copy(originalAudio, to: "audio.wav", in: stage, directory: stageURL)
        try Self.copy(transcriptionAudio, to: "transcription.wav", in: stage, directory: stageURL)
        try Self.write(Data(record.transcriptText.utf8), to: "transcript.txt", in: stage, directory: stageURL)
        try Self.write(metadata, to: "metadata.json", in: stage, directory: stageURL)

        // RENAME_EXCL atomically publishes the complete take, and refuses every collision.
        guard renameatx_np(dateDirectory, stageName, dateDirectory, name, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw DictationArchiveError.alreadyExists(path: finalURL.path) }
            throw Self.ioError("publish a recording", finalURL)
        }
        published = true
        return finalURL
    }

    private static let filenames = ["audio.wav", "transcription.wav", "transcript.txt", "metadata.json"]

    private func openArchive() throws -> Int32 {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard root.isFileURL, root.path != "/", root != home else {
            throw DictationArchiveError.unsafePath(path: root.path,
                reason: "Choose a dedicated folder, not your home directory or a filesystem root.")
        }
        let parentURL = root.deletingLastPathComponent()
        let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw Self.ioError("open the history folder’s parent", parentURL) }
        defer { close(parent) }
        let app = try Self.directory(root.lastPathComponent, in: parent, url: root)
        defer { close(app) }
        return try Self.directory("transcripts", in: app, url: transcriptsDirectory)
    }

    private static func directory(_ name: String, in parent: Int32, url: URL) throws -> Int32 {
        var information = stat()
        if fstatat(parent, name, &information, AT_SYMLINK_NOFOLLOW) == 0 {
            guard information.st_mode & S_IFMT != S_IFLNK else {
                throw DictationArchiveError.unsafePath(path: url.path, reason: "Symbolic links are not supported.")
            }
        } else if errno == ENOENT {
            if mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST {
                throw ioError("create a history folder", url)
            }
        } else {
            throw ioError("inspect a history folder", url)
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ioError("open a history folder", url) }
        guard fstat(descriptor, &information) == 0, information.st_uid == getuid() else {
            close(descriptor)
            throw DictationArchiveError.unsafePath(path: url.path, reason: "The history folder must belong to this user.")
        }
        guard fchmod(descriptor, mode_t(0o700)) == 0 else {
            let error = ioError("make a history folder private", url)
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func copy(_ source: URL, to filename: String, in directory: Int32, directory url: URL) throws {
        guard source.isFileURL else {
            throw DictationArchiveError.unsafePath(path: source.absoluteString, reason: "Audio must be a local file.")
        }
        var information = stat()
        if lstat(source.path, &information) == 0, information.st_mode & S_IFMT == S_IFLNK {
            throw DictationArchiveError.unsafePath(path: source.path, reason: "Symbolic links are not supported.")
        }
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw ioError("read the source audio", source) }
        defer { close(input) }
        guard fstat(input, &information) == 0, information.st_mode & S_IFMT == S_IFREG else {
            throw DictationArchiveError.unsafePath(path: source.path, reason: "Audio must be a regular file.")
        }
        let destination = url.appendingPathComponent(filename)
        let output = try newFile(filename, in: directory, url: destination)
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ioError("read the source audio", source)
            }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                try writeAll(UnsafeRawBufferPointer(rebasing: bytes[..<count]), to: output, url: destination)
            }
        }
        guard fsync(output) == 0 else { throw ioError("finish writing the audio", destination) }
    }

    private static func write(_ data: Data, to filename: String, in directory: Int32, directory url: URL) throws {
        let destination = url.appendingPathComponent(filename)
        let descriptor = try newFile(filename, in: directory, url: destination)
        defer { close(descriptor) }
        try data.withUnsafeBytes { try writeAll($0, to: descriptor, url: destination) }
        guard fsync(descriptor) == 0 else { throw ioError("finish writing a recording file", destination) }
    }

    private static func newFile(_ filename: String, in directory: Int32, url: URL) throws -> Int32 {
        let descriptor = openat(directory, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ioError("create a recording file", url) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            let error = ioError("make a recording file private", url)
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32, url: URL) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ioError("write a recording file", url) }
            offset += count
        }
    }

    private static func dateString(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func ioError(_ operation: String, _ url: URL) -> DictationArchiveError {
        .io(operation: operation, path: url.path, detail: String(cString: strerror(errno)))
    }
}
