import CryptoKit
import Foundation
import SQLite3
import SottoAPI

struct WisprFlowImportPreview: Sendable {
    let sessionCount: Int
    let transcriptCount: Int
    let metadataOnlyCount: Int
    let wavCount: Int
    let opusCount: Int
    let screenshotCount: Int
    let dictionaryCount: Int
    let earliestDate: Date?
    let latestDate: Date?
    let estimatedArtifactBytes: Int64
    let sourceURLs: [URL]
    let warnings: [String]
}

struct WisprFlowSourceArtifact: Sendable {
    let filename: WisprFlowArtifactName
    let url: URL
    let contentType: String
}

struct WisprFlowSourceSession: Sendable {
    let sourceID: UUID
    let createdAt: Date
    let displayText: String
    let rawText: String
    let sourceStatus: String?
    let durationSeconds: Double?
    let availableVariants: [String]
    let artifacts: [WisprFlowSourceArtifact]
}

enum WisprFlowSourceReaderError: LocalizedError {
    case noSources
    case unreadableSource(URL)
    case missingHistory(URL)
    case missingSourceID(URL)
    case invalidSourceID(String)
    case invalidTimestamp(UUID)
    case missingSession(UUID)
    case sqlite(String)
    case cannotCreateArtifact(URL)

    var errorDescription: String? {
        switch self {
        case .noSources: "No Wispr Flow database was found on this Mac."
        case .unreadableSource(let url): "Cannot read \(url.lastPathComponent)."
        case .missingHistory(let url): "\(url.lastPathComponent) has no History table."
        case .missingSourceID(let url): "\(url.lastPathComponent) has no transcriptEntityId column."
        case .invalidSourceID(let value): "A Wispr Flow session has an invalid ID: \(value)."
        case .invalidTimestamp(let id): "Wispr Flow session \(id) has no usable timestamp."
        case .missingSession(let id): "Wispr Flow session \(id) was not found in the snapshot."
        case .sqlite(let message): "Wispr Flow database error: \(message)"
        case .cannotCreateArtifact(let url): "Cannot create import artifact \(url.lastPathComponent)."
        }
    }
}

/// The source databases are opened read-only. SQLite's backup API copies a consistent
/// view, including a live WAL, into private temporary files before any row is read.
/// The reader owns those files and the lazily extracted artifacts until deinit.
final class WisprFlowSourceReader: @unchecked Sendable {
    private struct RowLocator {
        let databaseIndex: Int
        let rowID: Int64
        let timestamp: Date?
        let sourceStatus: String?
        let displayText: String
        let rawText: String
        let durationSeconds: Double?
        let mediaBytes: [String: Int64]
    }

    private final class Database {
        let sourceURL: URL
        let snapshotURL: URL
        let role: String
        let columns: Set<String>
        let dictionaryColumns: Set<String>
        let connection: OpaquePointer

        init(sourceURL: URL, snapshotURL: URL, role: String, connection: OpaquePointer,
             columns: Set<String>, dictionaryColumns: Set<String>) {
            self.sourceURL = sourceURL
            self.snapshotURL = snapshotURL
            self.role = role
            self.connection = connection
            self.columns = columns
            self.dictionaryColumns = dictionaryColumns
        }

        deinit { sqlite3_close_v2(connection) }
    }

    private static let mediaFilenames = [
        "audio": "source.wav",
        "opusChunks": "opus.json",
        "screenshot": "screenshot.png",
    ]
    private static let mediaContentTypes = [
        "source.wav": "audio/wav",
        "opus.json": "application/json",
        "screenshot.png": "image/png",
        "source.json": "application/json",
    ]
    private static let textVariantNames = [
        "pastedText", "serverFinalizedText", "formattedText", "asrText",
        "editedText", "editedTextUnbounded", "toneMatchedText",
        "defaultAsrText", "fallbackAsrText", "defaultFormattedText",
        "fallbackFormattedText", "desiredAsr", "desiredFormatted",
    ]

    let preview: WisprFlowImportPreview
    let sourceIDs: [UUID]
    private let temporaryDirectory: URL
    private let lock = NSLock()
    private var databases: [Database]
    private let locators: [UUID: [RowLocator]]

    static func discoverSourceURLs() -> [URL] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wispr Flow", isDirectory: true)
        let live = directory.appendingPathComponent("flow.sqlite")
        let backupsDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        let backups = ((try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { url in
                url.lastPathComponent.hasPrefix("backup-") && url.pathExtension == "sqlite"
                    && ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false)
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        return (FileManager.default.isReadableFile(atPath: live.path) ? [live] : []) + backups
    }

    init(sourceURLs: [URL]? = nil) throws {
        let selected = sourceURLs ?? Self.discoverSourceURLs()
        guard !selected.isEmpty else { throw WisprFlowSourceReaderError.noSources }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sotto-WisprFlow-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        temporaryDirectory = directory
        var opened: [Database] = []
        var rows: [UUID: [RowLocator]] = [:]
        var warnings: [String] = []
        do {
            for (index, source) in selected.enumerated() {
                guard source.pathExtension == "sqlite", !source.lastPathComponent.contains(".tmp"),
                      FileManager.default.isReadableFile(atPath: source.path) else {
                    throw WisprFlowSourceReaderError.unreadableSource(source)
                }
                let snapshot = directory.appendingPathComponent("source-\(index).sqlite")
                try Self.snapshot(source: source, destination: snapshot)
                let connection = try Self.openDatabase(snapshot, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                                                       immutable: true)
                let database: Database
                do {
                    try Self.quickCheck(connection)
                    let columns = try Self.columns(in: "History", database: connection)
                    guard !columns.isEmpty else { throw WisprFlowSourceReaderError.missingHistory(source) }
                    guard columns.contains("transcriptEntityId") else {
                        throw WisprFlowSourceReaderError.missingSourceID(source)
                    }
                    let dictionaryColumns = try Self.columns(in: "Dictionary", database: connection)
                    let role = source.lastPathComponent == "flow.sqlite" ? "current"
                        : (source.lastPathComponent.hasPrefix("backup-") ? "backup" : "selected")
                    database = Database(sourceURL: source, snapshotURL: snapshot, role: role,
                                        connection: connection, columns: columns,
                                        dictionaryColumns: dictionaryColumns)
                } catch {
                    sqlite3_close_v2(connection)
                    throw error
                }
                opened.append(database)
                for row in try Self.scan(database: database, index: index) {
                    rows[row.0, default: []].append(row.1)
                }
            }
            let ids = rows.keys.sorted { left, right in
                let leftDate = rows[left]?.compactMap(\.timestamp).first ?? .distantPast
                let rightDate = rows[right]?.compactMap(\.timestamp).first ?? .distantPast
                return leftDate == rightDate ? left.uuidString < right.uuidString : leftDate < rightDate
            }
            let entries = ids.compactMap { rows[$0] }
            let dated = entries.compactMap { $0.compactMap(\.timestamp).first }
            let transcriptCount = entries.filter { entry in
                entry.contains { !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }.count
            let wavCount = entries.filter { Self.hasMedia("audio", in: $0) }.count
            let opusCount = entries.filter { Self.hasMedia("opusChunks", in: $0) }.count
            let screenshotCount = entries.filter { Self.hasMedia("screenshot", in: $0) }.count
            let metadataOnlyCount = entries.filter { entry in
                !entry.contains { !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    && !Self.hasMedia("audio", in: entry) && !Self.hasMedia("opusChunks", in: entry)
            }.count
            let mediaBytes = entries.reduce(Int64(0)) { total, entry in
                total + Self.mediaFilenames.keys.reduce(Int64(0)) { amount, column in
                    amount + (entry.first { ($0.mediaBytes[column] ?? 0) > 0 }?.mediaBytes[column] ?? 0)
                }
            }
            if dated.count < ids.count { warnings.append("Some sessions have no usable timestamp and may fail to import.") }
            let dictionaryCount = try Self.dictionaryIDs(in: opened).count
            preview = WisprFlowImportPreview(
                sessionCount: ids.count, transcriptCount: transcriptCount,
                metadataOnlyCount: metadataOnlyCount, wavCount: wavCount,
                opusCount: opusCount, screenshotCount: screenshotCount,
                dictionaryCount: dictionaryCount, earliestDate: dated.min(), latestDate: dated.max(),
                estimatedArtifactBytes: mediaBytes + Int64(ids.count) * 16_384,
                sourceURLs: selected, warnings: warnings
            )
            sourceIDs = ids
            locators = rows
            databases = opened
        } catch {
            opened.removeAll()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        databases.removeAll()
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func session(for sourceID: UUID) throws -> WisprFlowSourceSession {
        lock.lock()
        defer { lock.unlock() }
        guard let rows = locators[sourceID], !rows.isEmpty else {
            throw WisprFlowSourceReaderError.missingSession(sourceID)
        }
        guard let createdAt = rows.compactMap(\.timestamp).first else {
            throw WisprFlowSourceReaderError.invalidTimestamp(sourceID)
        }
        let displayText = rows.first {
            !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.displayText ?? ""
        let rawText = rows.first {
            !$0.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.rawText ?? ""
        let sourceStatus = rows.compactMap(\.sourceStatus).first
        let durationSeconds = rows.compactMap(\.durationSeconds).first
        let artifactDirectory = temporaryDirectory.appendingPathComponent(sourceID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: artifactDirectory.path) {
            try FileManager.default.removeItem(at: artifactDirectory)
        }
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
        var artifacts: [WisprFlowSourceArtifact] = []
        var selectedMedia: [String: (databaseIndex: Int, rowID: Int64)] = [:]
        for (column, filename) in Self.mediaFilenames {
            for row in rows where (row.mediaBytes[column] ?? 0) > 0 {
                let output = artifactDirectory.appendingPathComponent(filename)
                do {
                    try Self.extract(column: column, rowID: row.rowID,
                                     from: databases[row.databaseIndex].connection, to: output)
                    guard try Self.isValidArtifact(output, filename: filename) else {
                        try? FileManager.default.removeItem(at: output)
                        continue
                    }
                    selectedMedia[column] = (row.databaseIndex, row.rowID)
                    guard let artifactName = WisprFlowArtifactName(rawValue: filename) else { continue }
                    artifacts.append(WisprFlowSourceArtifact(
                        filename: artifactName, url: output,
                        contentType: Self.mediaContentTypes[filename] ?? "application/octet-stream"
                    ))
                    break
                } catch {
                    try? FileManager.default.removeItem(at: output)
                    continue
                }
            }
        }
        var sources: [[String: Any]] = []
        var variants = Set<String>()
        for row in rows {
            let database = databases[row.databaseIndex]
            let values = try Self.sourceValues(for: row, in: database, selectedMedia: selectedMedia)
            for name in Self.textVariantNames {
                if let field = values[name], field["type"] as? String == "text",
                   let text = field["value"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    variants.insert(name)
                }
            }
            sources.append([
                "name": database.sourceURL.lastPathComponent,
                "role": database.role,
                "values": values,
            ])
        }
        let sourceDocument: [String: Any] = [
            "schemaVersion": 1,
            "provider": "wispr-flow",
            "sourceID": sourceID.uuidString,
            "sources": sources,
        ]
        let sourceURL = artifactDirectory.appendingPathComponent("source.json")
        try Self.writeJSON(sourceDocument, to: sourceURL)
        artifacts.insert(WisprFlowSourceArtifact(filename: .sourceJSON, url: sourceURL,
                                                contentType: "application/json"), at: 0)
        return WisprFlowSourceSession(
            sourceID: sourceID, createdAt: createdAt, displayText: displayText,
            rawText: rawText, sourceStatus: sourceStatus,
            durationSeconds: durationSeconds,
            availableVariants: Self.textVariantNames.filter { variants.contains($0) },
            artifacts: artifacts
        )
        } catch {
            try? FileManager.default.removeItem(at: artifactDirectory)
            throw error
        }
    }

    func dictionaryArtifactURL() throws -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard preview.dictionaryCount > 0 else { return nil }
        let url = temporaryDirectory.appendingPathComponent("dictionary.json")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var sources: [[String: Any]] = []
        for database in databases where !database.dictionaryColumns.isEmpty {
            let sql = "SELECT * FROM \"Dictionary\""
            let statement = try Self.prepare(sql, in: database.connection)
            defer { sqlite3_finalize(statement) }
            var rows: [[String: Any]] = []
            while try Self.nextRow(statement, in: database.connection) {
                var values: [String: Any] = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    values[name] = Self.typedValue(statement, column: column)
                }
                rows.append(values)
            }
            sources.append(["name": database.sourceURL.lastPathComponent,
                            "role": database.role, "rows": rows])
        }
        try Self.writeJSON(["schemaVersion": 1, "provider": "wispr-flow",
                            "table": "Dictionary", "sources": sources], to: url)
        return url
    }

    func deleteArtifacts(for sourceID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: temporaryDirectory.appendingPathComponent(sourceID.uuidString))
    }

    func discardArtifacts(for session: WisprFlowSourceSession) {
        deleteArtifacts(for: session.sourceID)
    }

    private static func hasMedia(_ column: String, in rows: [RowLocator]) -> Bool {
        rows.contains { ($0.mediaBytes[column] ?? 0) > 0 }
    }

    private static func openDatabase(_ url: URL, flags: Int32, immutable: Bool = false) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let address = immutable ? url.absoluteString + "?immutable=1" : url.path
        let result = sqlite3_open_v2(address, &connection, flags | (immutable ? SQLITE_OPEN_URI : 0), nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let connection { sqlite3_close_v2(connection) }
            throw WisprFlowSourceReaderError.sqlite("\(url.lastPathComponent): \(message)")
        }
        sqlite3_busy_timeout(connection, 5_000)
        return connection
    }

    private static func snapshot(source: URL, destination: URL) throws {
        // Never ask SQLite to open a live WAL inside Wispr Flow's directory: even
        // SQLITE_OPEN_READONLY may create a missing -shm file there. Copy its main
        // file and WAL by read-only filesystem reads, then let SQLite use private
        // temporary sidecars. A source without WAL is a fixed immutable main file.
        let sourceWAL = URL(fileURLWithPath: source.path + "-wal")
        let hasWAL = FileManager.default.fileExists(atPath: sourceWAL.path)
        let beforeMain = try FileManager.default.attributesOfItem(atPath: source.path)
        let beforeWAL = hasWAL ? try FileManager.default.attributesOfItem(atPath: sourceWAL.path) : nil
        let privateInput = destination.deletingPathExtension().appendingPathExtension("raw.sqlite")
        if hasWAL {
            try FileManager.default.copyItem(at: source, to: privateInput)
            try FileManager.default.copyItem(at: sourceWAL,
                                             to: URL(fileURLWithPath: privateInput.path + "-wal"))
        }
        defer {
            if hasWAL {
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: privateInput.path + suffix))
                }
            }
        }
        let input = try openDatabase(hasWAL ? privateInput : source,
                                     flags: (hasWAL ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX,
                                     immutable: !hasWAL)
        defer { sqlite3_close_v2(input) }
        let output = try openDatabase(destination, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(output) }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw WisprFlowSourceReaderError.sqlite(
                "Cannot snapshot \(source.lastPathComponent): \(String(cString: sqlite3_errmsg(output))) / \(String(cString: sqlite3_errmsg(input)))"
            )
        }
        var result: Int32 = SQLITE_OK
        var busyAttempts = 0
        repeat {
            result = sqlite3_backup_step(backup, 256)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                busyAttempts += 1
                if busyAttempts < 50 { sqlite3_sleep(100) }
            }
        } while result == SQLITE_OK || ((result == SQLITE_BUSY || result == SQLITE_LOCKED) && busyAttempts < 50)
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw WisprFlowSourceReaderError.sqlite(
                "Cannot finish snapshot \(source.lastPathComponent): \(String(cString: sqlite3_errmsg(output))) / \(String(cString: sqlite3_errmsg(input)))"
            )
        }
        let afterMain = try FileManager.default.attributesOfItem(atPath: source.path)
        let afterHasWAL = FileManager.default.fileExists(atPath: sourceWAL.path)
        let afterWAL = afterHasWAL ? try FileManager.default.attributesOfItem(atPath: sourceWAL.path) : nil
        guard sameFileState(beforeMain, afterMain), hasWAL == afterHasWAL,
              (!hasWAL || sameFileState(beforeWAL, afterWAL)) else {
            throw WisprFlowSourceReaderError.sqlite(
                "\(source.lastPathComponent) changed during its read-only snapshot. Pause Wispr Flow dictation and retry."
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func sameFileState(_ first: [FileAttributeKey: Any]?,
                                      _ second: [FileAttributeKey: Any]?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        return (first[.size] as? NSNumber) == (second[.size] as? NSNumber)
            && (first[.modificationDate] as? Date) == (second[.modificationDate] as? Date)
            && (first[.systemFileNumber] as? NSNumber) == (second[.systemFileNumber] as? NSNumber)
    }

    private static func quickCheck(_ database: OpaquePointer) throws {
        let statement = try prepare("PRAGMA quick_check", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, text(statement, column: 0) == "ok" else {
            throw WisprFlowSourceReaderError.sqlite("Snapshot integrity check failed.")
        }
    }

    private static func columns(in table: String, database: OpaquePointer) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\"\(table)\")", in: database)
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while try nextRow(statement, in: database) {
            if let name = text(statement, column: 1) { names.insert(name) }
        }
        return names
    }

    private static func scan(database: Database, index: Int) throws -> [(UUID, RowLocator)] {
        func field(_ name: String) -> String {
            database.columns.contains(name) ? "\"\(name)\"" : "NULL"
        }
        func length(_ name: String) -> String {
            database.columns.contains(name) ? "length(\"\(name)\")" : "0"
        }
        let sql = """
            SELECT rowid, \(field("transcriptEntityId")), \(field("timestamp")),
                   \(field("pastedText")), \(field("serverFinalizedText")),
                   \(field("formattedText")), \(field("asrText")),
                   \(field("status")), \(field("duration")), \(field("speechDuration")),
                   \(length("audio")), \(length("opusChunks")), \(length("screenshot"))
            FROM "History"
            """
        let statement = try prepare(sql, in: database.connection)
        defer { sqlite3_finalize(statement) }
        var rows: [(UUID, RowLocator)] = []
        while try nextRow(statement, in: database.connection) {
            let idText = text(statement, column: 1) ?? ""
            guard let id = UUID(uuidString: idText) else {
                throw WisprFlowSourceReaderError.invalidSourceID(idText)
            }
            let candidates = (3...6).compactMap { text(statement, column: Int32($0)) }
            let display = candidates.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
            let duration = number(statement, column: 8) ?? number(statement, column: 9)
            let media = [
                "audio": sqlite3_column_int64(statement, 10),
                "opusChunks": sqlite3_column_int64(statement, 11),
                "screenshot": sqlite3_column_int64(statement, 12),
            ]
            rows.append((id, RowLocator(
                databaseIndex: index, rowID: sqlite3_column_int64(statement, 0),
                timestamp: text(statement, column: 2).flatMap(parseDate),
                sourceStatus: text(statement, column: 7), displayText: display,
                rawText: text(statement, column: 6) ?? "",
                durationSeconds: duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                mediaBytes: media
            )))
        }
        return rows
    }

    private static func dictionaryIDs(in databases: [Database]) throws -> Set<String> {
        var ids = Set<String>()
        for database in databases where !database.dictionaryColumns.isEmpty {
            let idExpression = database.dictionaryColumns.contains("id") ? "CAST(\"id\" AS TEXT)" : "CAST(rowid AS TEXT)"
            let statement = try prepare("SELECT \(idExpression) FROM \"Dictionary\"", in: database.connection)
            defer { sqlite3_finalize(statement) }
            while try nextRow(statement, in: database.connection) {
                if let id = text(statement, column: 0) { ids.insert(id) }
            }
        }
        return ids
    }

    private static func sourceValues(
        for row: RowLocator, in database: Database,
        selectedMedia: [String: (databaseIndex: Int, rowID: Int64)]
    ) throws -> [String: [String: Any]] {
        let statement = try prepare("SELECT * FROM \"History\" WHERE rowid = ?", in: database.connection)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, row.rowID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw WisprFlowSourceReaderError.sqlite("A snapshotted History row disappeared.")
        }
        var values: [String: [String: Any]] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            if name == "audio" || name == "opusChunks" || name == "screenshot" || name == "builtInAudio" {
                let type = sqliteType(sqlite3_column_type(statement, index))
                if type == "null" { values[name] = ["type": "null"] }
                else {
                    var reference: [String: Any] = ["type": type, "byteCount": Int(sqlite3_column_bytes(statement, index))]
                    reference["sha256"] = try hashBlob(column: name, rowID: row.rowID,
                                                       from: database.connection)
                    if let selected = selectedMedia[name], selected.databaseIndex == row.databaseIndex,
                       selected.rowID == row.rowID, let filename = mediaFilenames[name] {
                        reference["artifact"] = filename
                    }
                    values[name] = reference
                }
            } else {
                values[name] = typedValue(statement, column: index)
            }
        }
        return values
    }

    private static func typedValue(_ statement: OpaquePointer, column: Int32) -> [String: Any] {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL: return ["type": "null"]
        case SQLITE_INTEGER: return ["type": "integer", "value": sqlite3_column_int64(statement, column)]
        case SQLITE_FLOAT:
            let value = sqlite3_column_double(statement, column)
            return value.isFinite ? ["type": "real", "value": value]
                : ["type": "real", "value": String(value)]
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard let pointer = sqlite3_column_text(statement, column) else { return ["type": "text", "value": ""] }
            let bytes = Data(bytes: pointer, count: count)
            if let value = String(data: bytes, encoding: .utf8) { return ["type": "text", "value": value] }
            return ["type": "text", "base64": bytes.base64EncodedString(), "encoding": "raw-bytes"]
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard let pointer = sqlite3_column_blob(statement, column) else { return ["type": "blob", "base64": ""] }
            return ["type": "blob", "base64": Data(bytes: pointer, count: count).base64EncodedString()]
        default: return ["type": "null"]
        }
    }

    private static func sqliteType(_ type: Int32) -> String {
        switch type {
        case SQLITE_INTEGER: "integer"
        case SQLITE_FLOAT: "real"
        case SQLITE_TEXT: "text"
        case SQLITE_BLOB: "blob"
        default: "null"
        }
    }

    private static func extract(column: String, rowID: Int64, from database: OpaquePointer, to url: URL) throws {
        var blob: OpaquePointer?
        let result = sqlite3_blob_open(database, "main", "History", column, rowID, 0, &blob)
        guard result == SQLITE_OK, let blob else {
            throw WisprFlowSourceReaderError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_blob_close(blob) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw WisprFlowSourceReaderError.cannotCreateArtifact(url)
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let size = Int(sqlite3_blob_bytes(blob))
        var offset = 0
        while offset < size {
            let count = min(65_536, size - offset)
            var buffer = [UInt8](repeating: 0, count: count)
            let readResult = buffer.withUnsafeMutableBytes { bytes in
                sqlite3_blob_read(blob, bytes.baseAddress, Int32(count), Int32(offset))
            }
            guard readResult == SQLITE_OK else {
                throw WisprFlowSourceReaderError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            try output.write(contentsOf: Data(buffer))
            offset += count
        }
    }

    private static func hashBlob(column: String, rowID: Int64, from database: OpaquePointer) throws -> String {
        var blob: OpaquePointer?
        guard sqlite3_blob_open(database, "main", "History", column, rowID, 0, &blob) == SQLITE_OK,
              let blob else {
            throw WisprFlowSourceReaderError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_blob_close(blob) }
        var hasher = SHA256()
        let size = Int(sqlite3_blob_bytes(blob))
        var offset = 0
        while offset < size {
            let count = min(65_536, size - offset)
            var buffer = [UInt8](repeating: 0, count: count)
            let result = buffer.withUnsafeMutableBytes { bytes in
                sqlite3_blob_read(blob, bytes.baseAddress, Int32(count), Int32(offset))
            }
            guard result == SQLITE_OK else {
                throw WisprFlowSourceReaderError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            hasher.update(data: Data(buffer))
            offset += count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidArtifact(_ url: URL, filename: String) throws -> Bool {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let header = try input.read(upToCount: 12) ?? Data()
        switch filename {
        case "source.wav":
            return header.count >= 12 && header.prefix(4) == Data("RIFF".utf8)
                && header.dropFirst(8).prefix(4) == Data("WAVE".utf8)
        case "screenshot.png":
            return header.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10])
        case "opus.json":
            let data = try Data(contentsOf: url)
            guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
            return object is [String: Any]
        default: return false
        }
    }

    private static func writeJSON(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WisprFlowSourceReaderError.sqlite("\(sql.prefix(80)): \(String(cString: sqlite3_errmsg(database)))")
        }
        return statement
    }

    private static func nextRow(_ statement: OpaquePointer, in database: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: true
        case SQLITE_DONE: false
        default: throw WisprFlowSourceReaderError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        let bytes = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        return String(data: bytes, encoding: .utf8)
    }

    private static func number(_ statement: OpaquePointer, column: Int32) -> Double? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER, SQLITE_FLOAT: sqlite3_column_double(statement, column)
        default: nil
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        if let date = formatter.date(from: value) { return date }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        if let date = formatter.date(from: value) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: value)
    }
}
