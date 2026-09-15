import Foundation
import SQLite3
import SottoAPI
@testable import Sotto
import XCTest

final class WisprFlowSourceReaderTests: XCTestCase {
    func testActiveWALSnapshotIncludesUncheckpointedRowWithoutTouchingSourceFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-flow-active-wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("flow.sqlite")
        var connection: OpaquePointer?
        guard sqlite3_open(source.path, &connection) == SQLITE_OK, let connection else {
            throw NSError(domain: "WisprFlowFixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not open WAL fixture."])
        }
        defer { sqlite3_close(connection) }
        let sql = """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE History (transcriptEntityId TEXT PRIMARY KEY, timestamp TEXT, pastedText TEXT);
            INSERT INTO History VALUES ('\(Fixture.sharedID.uuidString)', '2026-01-03 12:00:00.000 +00:00', 'Uncheckpointed text');
            """
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "WisprFlowFixture", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection))])
        }
        let sourceFiles = [source, URL(fileURLWithPath: source.path + "-wal"), URL(fileURLWithPath: source.path + "-shm")]
        let before = try sourceFiles.map { try Data(contentsOf: $0) }

        let reader = try WisprFlowSourceReader(sourceURLs: [source])
        XCTAssertEqual(reader.sourceIDs, [Fixture.sharedID])
        XCTAssertEqual(try reader.session(for: Fixture.sharedID).displayText, "Uncheckpointed text")
        for (index, url) in sourceFiles.enumerated() { XCTAssertEqual(try Data(contentsOf: url), before[index]) }
    }

    func testClosedWALModeSourceCanBeSnapshottedAndReopened() throws {
        let fixture = try Fixture(walMode: true)
        defer { fixture.remove() }
        let live = fixture.urls[0]
        let before = try Data(contentsOf: live)
        XCTAssertEqual(before[18], 2)
        XCTAssertEqual(before[19], 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path + "-wal"))

        let reader = try WisprFlowSourceReader(sourceURLs: fixture.urls)
        XCTAssertEqual(reader.preview.sessionCount, 3)
        XCTAssertEqual(reader.sourceIDs, [Fixture.sharedID, Fixture.textOnlyID, Fixture.metadataOnlyID])
        XCTAssertEqual(try Data(contentsOf: live), before)
    }

    func testSnapshotMergesBackupMediaWithoutChangingReadOnlySources() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sourceBytes = try fixture.urls.map { try Data(contentsOf: $0) }
        let sourceDates = try fixture.urls.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let reader = try WisprFlowSourceReader(sourceURLs: fixture.urls)

        XCTAssertEqual(reader.sourceIDs, [Fixture.sharedID, Fixture.textOnlyID, Fixture.metadataOnlyID])
        let shared = try reader.session(for: Fixture.sharedID)
        XCTAssertEqual(shared.displayText, "Current pasted text")
        XCTAssertEqual(shared.rawText, "Current ASR text")
        XCTAssertEqual(Set(shared.artifacts.map(\.filename)), [.sourceJSON, .sourceWAV, .opusJSON])
        let wav = try XCTUnwrap(shared.artifacts.first(where: { $0.filename == .sourceWAV }))
        XCTAssertEqual(try Data(contentsOf: wav.url), Fixture.backupWAV)
        let source = try XCTUnwrap(shared.artifacts.first(where: { $0.filename == .sourceJSON }))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.url)) as? [String: Any])
        let versions = try XCTUnwrap(document["sources"] as? [[String: Any]])
        XCTAssertEqual(versions.count, 2)
        let current = try XCTUnwrap(versions.first?["values"] as? [String: [String: Any]])
        XCTAssertEqual(current["pastedText"]?["value"] as? String, "Current pasted text")
        XCTAssertEqual(current["duration"]?["type"] as? String, "real")
        let backup = try XCTUnwrap(versions.last?["values"] as? [String: [String: Any]])
        XCTAssertEqual(backup["audio"]?["artifact"] as? String, "source.wav")

        let textOnly = try reader.session(for: Fixture.textOnlyID)
        XCTAssertEqual(textOnly.displayText, "Finalized text only")
        XCTAssertFalse(textOnly.artifacts.contains(where: { $0.filename == .sourceWAV }))

        let metadataOnly = try reader.session(for: Fixture.metadataOnlyID)
        XCTAssertTrue(metadataOnly.displayText.isEmpty)
        XCTAssertFalse(metadataOnly.artifacts.contains(where: { $0.filename == .sourceWAV }))

        for (index, url) in fixture.urls.enumerated() {
            XCTAssertEqual(try Data(contentsOf: url), sourceBytes[index])
            XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, sourceDates[index])
        }
    }

    func testOversizedCurrentWAVStillImportsTextAndUsesSmallerBackupWithExplicitOmission() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addOversizedCurrentWAV()
        let reader = try WisprFlowSourceReader(sourceURLs: fixture.urls)
        let session = try reader.session(for: Fixture.sharedID)
        XCTAssertEqual(session.displayText, "Current pasted text")
        let wav = try XCTUnwrap(session.artifacts.first(where: { $0.filename == .sourceWAV }))
        XCTAssertEqual(try Data(contentsOf: wav.url), Fixture.backupWAV)
        let missing = try XCTUnwrap(session.unarchivedArtifacts.first(where: { $0.filename == .sourceWAV }))
        XCTAssertEqual(missing.byteCount, WisprFlowImportLimits.maximumArtifactBytes + 1)
        XCTAssertEqual(missing.sha256.count, 64)
        let source = try XCTUnwrap(session.artifacts.first(where: { $0.filename == .sourceJSON }))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.url)) as? [String: Any])
        let omissions = try XCTUnwrap(document["archiveOmissions"] as? [[String: Any]])
        XCTAssertEqual(omissions.first?["sourceName"] as? String, "live.sqlite")
        XCTAssertEqual(omissions.first?["observedSHA256"] as? String, missing.sha256)
        XCTAssertEqual(omissions.first?["observedByteCount"] as? Int, missing.byteCount)
        XCTAssertEqual(omissions.first?["reason"] as? String, "exceeds-upload-limit")
        XCTAssertEqual(omissions.first?["status"] as? String, "not-archived")

        let currentOnly = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        let textOnly = try currentOnly.session(for: Fixture.sharedID)
        XCTAssertEqual(textOnly.artifacts.map(\.filename), [.sourceJSON])
        XCTAssertEqual(textOnly.unarchivedArtifacts.map(\.filename), [.sourceWAV])
        XCTAssertEqual(textOnly.displayText, "Current pasted text")
    }

    func testDictionaryLargerThanOldLimitIsWholeAndAboveNewLimitFailsClearly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addDictionaryRows(count: 1_000, valueSize: 400)
        let reader = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        XCTAssertEqual(reader.preview.dictionaryCount, 1_000)
        let url = try XCTUnwrap(reader.dictionaryArtifactURL())
        let archive = try Data(contentsOf: url)
        XCTAssertGreaterThan(archive.count, 262_144)
        XCTAssertLessThan(archive.count, WisprFlowImportLimits.maximumDictionaryBytes)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        let sources = try XCTUnwrap(document["sources"] as? [[String: Any]])
        let rows = try XCTUnwrap(sources.first?["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1_000)

        try fixture.addOversizedDictionaryBlob()
        let oversizedReader = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        XCTAssertThrowsError(try oversizedReader.dictionaryArtifactURL()) { error in
            guard case WisprFlowSourceReaderError.dictionaryTooLarge(let bytes) = error else {
                return XCTFail("Expected a size-specific dictionary error, got \(error)")
            }
            XCTAssertGreaterThan(bytes, WisprFlowImportLimits.maximumDictionaryBytes)
        }
    }

    func testMalformedSourceIDsAreSkippedAndCountedWithoutBlockingValidHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addMalformedSourceIDs()
        let reader = try WisprFlowSourceReader(sourceURLs: fixture.urls)
        XCTAssertEqual(reader.preview.sessionCount, 3)
        XCTAssertEqual(reader.sourceIDs, [Fixture.sharedID, Fixture.textOnlyID, Fixture.metadataOnlyID])
        XCTAssertTrue(reader.preview.warnings.contains { $0.contains("Skipped 3 History rows") })
        XCTAssertEqual(try reader.session(for: Fixture.sharedID).displayText, "Current pasted text")
    }

    func testUnknownBuiltInAudioIsRecordedAsUnarchivedMedia() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addBuiltInAudioBlob()
        let reader = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        let session = try reader.session(for: Fixture.sharedID)
        XCTAssertEqual(session.artifacts.map(\.filename), [.sourceJSON])
        let omitted = try XCTUnwrap(session.unarchivedArtifacts.first(where: { $0.filename == .builtInAudio }))
        XCTAssertEqual(omitted.byteCount, 128)
        XCTAssertEqual(omitted.sha256.count, 64)
        let source = try XCTUnwrap(session.artifacts.first)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.url)) as? [String: Any])
        let omissions = try XCTUnwrap(document["archiveOmissions"] as? [[String: Any]])
        XCTAssertEqual(omissions.first?["sourceColumn"] as? String, "builtInAudio")
        XCTAssertEqual(omissions.first?["reason"] as? String, "unsupported-source-column")
        XCTAssertEqual(omissions.first?["observedSHA256"] as? String, omitted.sha256)
    }

    private struct Fixture {
        static let sharedID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        static let textOnlyID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        static let metadataOnlyID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        static let backupWAV = Data([0x52, 0x49, 0x46, 0x46, 0x26, 0, 0, 0, 0x57, 0x41, 0x56, 0x45,
                                     0x66, 0x6d, 0x74, 0x20, 0x10, 0, 0, 0, 1, 0, 1, 0,
                                     0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0,
                                     0x64, 0x61, 0x74, 0x61, 2, 0, 0, 0, 0, 0])

        let directory: URL
        let urls: [URL]

        init(walMode: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-flow-reader-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let live = directory.appendingPathComponent("live.sqlite")
            let backup = directory.appendingPathComponent("backup.sqlite")
            try Self.makeDatabase(at: live, walMode: walMode, rows: """
                INSERT INTO History VALUES ('\(Self.sharedID.uuidString)', '2026-01-03 12:00:00.000 +00:00', 'Current ASR text', 'Current formatted text', 'Current pasted text', 'Current finalized text', NULL, NULL, 'COMPLETED', 1.25);
                INSERT INTO History VALUES ('\(Self.textOnlyID.uuidString)', '2026-01-04 12:00:00.000 +00:00', 'Text-only ASR', NULL, NULL, 'Finalized text only', NULL, NULL, 'COMPLETED', 2.0);
                INSERT INTO History VALUES ('\(Self.metadataOnlyID.uuidString)', '2026-01-05 12:00:00.000 +00:00', NULL, NULL, NULL, NULL, NULL, NULL, 'FAILED', NULL);
                """)
            try Self.makeDatabase(at: backup, rows: """
                INSERT INTO History VALUES ('\(Self.sharedID.uuidString)', '2026-01-03 12:00:00.000 +00:00', 'Old ASR text', NULL, 'Old pasted text', NULL, x'\(Self.backupWAV.map { String(format: "%02x", $0) }.joined())', '{"chunks":[]}', 'COMPLETED', 1.25);
                """)
            if walMode {
                for suffix in ["-wal", "-shm"] {
                    try? FileManager.default.removeItem(atPath: live.path + suffix)
                }
            }
            for url in [live, backup] { try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path) }
            urls = [live, backup]
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func addOversizedCurrentWAV() throws {
            try withWritableLiveDatabase { database in
                let sql = "UPDATE History SET audio = zeroblob(\(WisprFlowImportLimits.maximumArtifactBytes + 1)) WHERE transcriptEntityId = '\(Self.sharedID.uuidString)'"
                guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
                }
                var blob: OpaquePointer?
                guard sqlite3_blob_open(database, "main", "History", "audio", 1, 1, &blob) == SQLITE_OK,
                      let blob else { throw NSError(domain: "WisprFlowFixture", code: 6) }
                defer { sqlite3_blob_close(blob) }
                let header: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45]
                guard header.withUnsafeBytes({ sqlite3_blob_write(blob, $0.baseAddress, Int32(header.count), 0) }) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 7)
                }
            }
        }

        func addDictionaryRows(count: Int, valueSize: Int) throws {
            try withWritableLiveDatabase { database in
                guard sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS Dictionary (id TEXT PRIMARY KEY, phrase TEXT)", nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 8)
                }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "INSERT INTO Dictionary VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK,
                      let statement else { throw NSError(domain: "WisprFlowFixture", code: 9) }
                defer { sqlite3_finalize(statement) }
                let phrase = String(repeating: "a", count: valueSize)
                for index in 0..<count {
                    let identifier = "entry-\(index)"
                    try identifier.withCString { idPointer in
                        try phrase.withCString { phrasePointer in
                            sqlite3_bind_text(statement, 1, idPointer, -1, nil)
                            sqlite3_bind_text(statement, 2, phrasePointer, -1, nil)
                            guard sqlite3_step(statement) == SQLITE_DONE else {
                                throw NSError(domain: "WisprFlowFixture", code: 10)
                            }
                        }
                    }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }
        }

        func addOversizedDictionaryBlob() throws {
            try withWritableLiveDatabase { database in
                guard sqlite3_exec(database, "ALTER TABLE Dictionary ADD COLUMN payload BLOB", nil, nil, nil) == SQLITE_OK,
                      sqlite3_exec(database, "INSERT INTO Dictionary (id, payload) VALUES ('huge', zeroblob(7000000))", nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 11)
                }
            }
        }

        func addMalformedSourceIDs() throws {
            try withWritableLiveDatabase { database in
                let sql = """
                    INSERT INTO History (transcriptEntityId, timestamp, pastedText)
                        VALUES (NULL, '2026-01-06 12:00:00.000 +00:00', 'Bad null ID');
                    INSERT INTO History (transcriptEntityId, timestamp, pastedText)
                        VALUES ('', '2026-01-07 12:00:00.000 +00:00', 'Bad empty ID');
                    INSERT INTO History (transcriptEntityId, timestamp, pastedText)
                        VALUES ('not-a-uuid', '2026-01-08 12:00:00.000 +00:00', 'Bad text ID');
                    """
                guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 13,
                                  userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
                }
            }
        }

        func addBuiltInAudioBlob() throws {
            try withWritableLiveDatabase { database in
                guard sqlite3_exec(database, "ALTER TABLE History ADD COLUMN builtInAudio BLOB", nil, nil, nil) == SQLITE_OK,
                      sqlite3_exec(database, "UPDATE History SET builtInAudio = zeroblob(128) WHERE rowid = 1", nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 14)
                }
            }
        }

        private func withWritableLiveDatabase(_ operation: (OpaquePointer) throws -> Void) throws {
            let live = urls[0]
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: live.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: live.path) }
            var database: OpaquePointer?
            guard sqlite3_open(live.path, &database) == SQLITE_OK, let database else {
                throw NSError(domain: "WisprFlowFixture", code: 12)
            }
            defer { sqlite3_close(database) }
            try operation(database)
        }

        private static func makeDatabase(at url: URL, walMode: Bool = false, rows: String) throws {
            var database: OpaquePointer?
            guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
                throw NSError(domain: "WisprFlowFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create SQLite fixture."])
            }
            defer { sqlite3_close(database) }
            let sql = """
                \(walMode ? "PRAGMA journal_mode=WAL;" : "")
                CREATE TABLE History (
                    transcriptEntityId TEXT PRIMARY KEY, timestamp TEXT,
                    asrText TEXT, formattedText TEXT, pastedText TEXT, serverFinalizedText TEXT,
                    audio BLOB, opusChunks TEXT, status TEXT, duration REAL
                );
                \(rows)
                \(walMode ? "PRAGMA wal_checkpoint(TRUNCATE);" : "")
                """
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "Unknown SQLite error."
                sqlite3_free(error)
                throw NSError(domain: "WisprFlowFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }
}
