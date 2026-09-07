import Darwin
import Foundation

public struct DictationHistoryEntry: Identifiable, Equatable, Sendable {
    public let folder: URL
    public let record: DictationArchiveRecord
    public let hasOriginalAudio: Bool
    public var id: URL { folder }
    public var audioURL: URL { folder.appendingPathComponent("audio.wav") }
}

public struct DictationHistoryPage: Sendable {
    public let entries: [DictationHistoryEntry]
    public let hasMore: Bool
    public let skippedCount: Int
}

public enum DictationHistoryReadError: LocalizedError, Sendable {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let detail): return "Couldn't read local history. \(detail)" }
    }
}

/// On-demand, bounded archive browsing. Never creates, edits, or follows linked
/// take directories, and never uses filenames supplied by decoded metadata.
public actor DictationArchiveReader {
    public let directory: URL
    private static let maximumMetadataBytes = 1_048_576
    private let files = FileManager.default

    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    public func read(limit: Int = 200) -> Result<DictationHistoryPage, DictationHistoryReadError> {
        guard limit > 0 else { return .success(.init(entries: [], hasMore: false, skippedCount: 0)) }
        guard files.fileExists(atPath: directory.path) else {
            return .success(.init(entries: [], hasMore: false, skippedCount: 0))
        }
        guard Self.isDirectory(directory) else { return .failure(.unavailable("The archive must be a regular folder, not a link.")) }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                let format = ISO8601DateFormatter()
                format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = format.date(from: value) { return date }
                format.formatOptions = [.withInternetDateTime]
                guard let date = format.date(from: value) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid archive date")
                }
                return date
            }
            let days = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                .filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil && Self.isDirectory($0) }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            var entries: [DictationHistoryEntry] = []
            var skipped = 0
            for day in days {
                try Task.checkCancellation()
                let takes = try files.contentsOfDirectory(at: day, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                    .filter(Self.isDirectory).sorted { $0.lastPathComponent > $1.lastPathComponent }
                for take in takes {
                    try Task.checkCancellation()
                    guard let data = Self.readMetadata(take.appendingPathComponent("metadata.json")),
                          let record = try? decoder.decode(DictationArchiveRecord.self, from: data),
                          record.schemaVersion == 1 else { skipped += 1; continue }
                    if entries.count == limit { return .success(.init(entries: entries, hasMore: true, skippedCount: skipped)) }
                    let audio = take.appendingPathComponent("audio.wav")
                    entries.append(.init(folder: take, record: record, hasOriginalAudio: Self.isRegularFile(audio)))
                }
            }
            return .success(.init(entries: entries, hasMore: false, skippedCount: skipped))
        } catch {
            return .failure(.unavailable(error.localizedDescription))
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func readMetadata(_ url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumMetadataBytes,
              let data = try? handle.read(upToCount: maximumMetadataBytes + 1),
              data.count <= maximumMetadataBytes else { return nil }
        return data
    }
}
