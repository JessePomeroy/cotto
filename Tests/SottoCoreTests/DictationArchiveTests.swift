import Foundation
import XCTest
@testable import SottoCore

final class DictationArchiveTests: XCTestCase {
    func testSavePublishesTextMetadataAndIndependentAudioCopiesPrivately() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = Self.record(textProcessing: TextProcessingRecord(
            dictionaryTerms: ["MiniMax", "Codex"], dictionaryChangedText: false,
            inputText: "1. oranges\n2. a trip to the beach", outputText: "1. Oranges\n2. A trip to the beach",
            enabled: true, status: .applied, modelID: "fixture-text-model", modelSHA256: "fixture-text-sha256",
            engineVersion: "fixture-text-engine", processingSeconds: 0.5, wallSeconds: 0.7))
        let writer = DictationArchiveWriter(root: fixture.root)
        let result = await writer.save(record: record, originalAudio: fixture.original,
                                       transcriptionAudio: fixture.transcription)
        let take = try result.get()

        XCTAssertEqual(take.deletingLastPathComponent().lastPathComponent, "2026-09-04")
        XCTAssertEqual(take.lastPathComponent, "2026-09-04T12-00-00.000Z-11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: take.path)),
                       ["transcript.txt", "metadata.json", "audio.wav", "transcription.wav"])
        XCTAssertEqual(try String(contentsOf: take.appendingPathComponent("transcript.txt"), encoding: .utf8),
                       "1. Oranges\n2. A trip to the beach")
        XCTAssertEqual(try Data(contentsOf: take.appendingPathComponent("audio.wav")), try Data(contentsOf: fixture.original))
        XCTAssertEqual(try Data(contentsOf: take.appendingPathComponent("transcription.wav")), try Data(contentsOf: fixture.transcription))

        let metadata = try Data(contentsOf: take.appendingPathComponent("metadata.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let timestamp = try value.decode(String.self)
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = format.date(from: timestamp) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected ISO 8601 date")
            }
            return date
        }
        XCTAssertEqual(try decoder.decode(DictationArchiveRecord.self, from: metadata), record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["startedAt"] as? String, "2026-09-04T12:00:00.000Z")
        let processing = try XCTUnwrap(json["textProcessing"] as? [String: Any])
        XCTAssertEqual(processing["inputText"] as? String, record.textProcessing?.inputText)
        XCTAssertEqual(processing["outputText"] as? String, record.transcriptText)
        XCTAssertEqual(processing["modelID"] as? String, "fixture-text-model")
        XCTAssertEqual(processing["modelSHA256"] as? String, "fixture-text-sha256")
        XCTAssertEqual(json["rawText"] as? String, record.rawText)
        let audio = try XCTUnwrap(json["audio"] as? [String: Any])
        XCTAssertEqual(audio["originalFilename"] as? String, "audio.wav")
        XCTAssertEqual(audio["transcriptionFilename"] as? String, "transcription.wav")
        for directory in [fixture.root, writer.transcriptsDirectory, take.deletingLastPathComponent(), take] {
            XCTAssertEqual(try Self.permissions(directory), 0o700)
        }
        for name in ["transcript.txt", "metadata.json", "audio.wav", "transcription.wav"] {
            XCTAssertEqual(try Self.permissions(take.appendingPathComponent(name)), 0o600)
        }
        // Audio lifetime belongs to the caller, and archive copies do not share an inode.
        try Data("changed source".utf8).write(to: fixture.original)
        XCTAssertNotEqual(try Data(contentsOf: take.appendingPathComponent("audio.wav")), try Data(contentsOf: fixture.original))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.transcription.path))
    }

    func testLegacyMetadataWithoutTextProcessingStillDecodes() throws {
        let record = Self.record()
        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["textProcessing"])
        XCTAssertEqual(try JSONDecoder().decode(DictationArchiveRecord.self, from: data), record)
    }

    func testPrepareUsesCustomRootAndNeverChangesTheParentPermissions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let parentPermissions = try Self.permissions(fixture.parent)
        let writer = DictationArchiveWriter(root: fixture.root)
        let first = await writer.prepare()
        let second = await writer.prepare()
        XCTAssertEqual(try first.get(), fixture.root.appendingPathComponent("transcripts", isDirectory: true))
        XCTAssertEqual(try second.get(), writer.transcriptsDirectory)
        XCTAssertEqual(try Self.permissions(fixture.root), 0o700)
        XCTAssertEqual(try Self.permissions(fixture.parent), parentPermissions)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: writer.transcriptsDirectory.path).isEmpty)
    }

    func testDuplicateIdentityNeverOverwritesAndLeavesNoPartialTake() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = DictationArchiveWriter(root: fixture.root)
        let first = await writer.save(record: Self.record(), originalAudio: fixture.original,
                                     transcriptionAudio: fixture.transcription)
        let take = try first.get()
        let originalBytes = try Data(contentsOf: take.appendingPathComponent("audio.wav"))
        try Data("different audio".utf8).write(to: fixture.original)
        let second = await writer.save(record: Self.record(text: "Do not replace me"),
                                      originalAudio: fixture.original, transcriptionAudio: fixture.transcription)
        guard case .failure(.alreadyExists(let path)) = second else { return XCTFail("Expected an explicit collision") }
        XCTAssertEqual(path, take.path)
        XCTAssertEqual(try Data(contentsOf: take.appendingPathComponent("audio.wav")), originalBytes)
        XCTAssertEqual(try String(contentsOf: take.appendingPathComponent("transcript.txt"), encoding: .utf8),
                       Self.record().transcriptText)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: take.deletingLastPathComponent().path),
                       [take.lastPathComponent])
    }

    func testFailureAfterFirstAudioCopyRemovesPartialDataAndPreservesSources() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = DictationArchiveWriter(root: fixture.root)
        let result = await writer.save(record: Self.record(), originalAudio: fixture.original,
                                       transcriptionAudio: fixture.parent.appendingPathComponent("missing.wav"))
        guard case .failure(.io(let operation, let path, _)) = result else { return XCTFail("Expected missing-audio error") }
        XCTAssertEqual(operation, "read the source audio")
        XCTAssertTrue(path.hasSuffix("missing.wav"))
        let date = writer.transcriptsDirectory.appendingPathComponent("2026-09-04")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: date.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.transcription.path))
    }

    func testArchivePathSymlinksAreRefusedWithoutModifyingTheirTargets() async throws {
        for component in ["root", "transcripts", "date"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let target = fixture.parent.appendingPathComponent("unrelated", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o755])
            let targetPermissions = try Self.permissions(target)
            let link: URL
            if component == "root" {
                link = fixture.root
            } else {
                try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
                let transcripts = fixture.root.appendingPathComponent("transcripts", isDirectory: true)
                if component == "transcripts" { link = transcripts }
                else {
                    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: false)
                    link = transcripts.appendingPathComponent("2026-09-04", isDirectory: true)
                }
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let writer = DictationArchiveWriter(root: fixture.root)
            let result = await writer.save(record: Self.record(), originalAudio: fixture.original,
                                           transcriptionAudio: fixture.transcription)
            guard case .failure(.unsafePath(let path, _)) = result else { return XCTFail("Expected refusal of \(component) symlink") }
            XCTAssertEqual(path, link.path)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
            XCTAssertEqual(try Self.permissions(target), targetPermissions)
        }
    }

    func testBothAudioSourceSymlinksAreRefusedAndPartialTakeIsRemoved() async throws {
        for replaceOriginal in [true, false] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let linkedAudio = fixture.parent.appendingPathComponent("linked.wav")
            try FileManager.default.createSymbolicLink(at: linkedAudio, withDestinationURL: fixture.original)
            let writer = DictationArchiveWriter(root: fixture.root)
            let result = await writer.save(record: Self.record(),
                originalAudio: replaceOriginal ? linkedAudio : fixture.original,
                transcriptionAudio: replaceOriginal ? fixture.transcription : linkedAudio)
            guard case .failure(.unsafePath(let path, _)) = result else { return XCTFail("Expected audio-symlink refusal") }
            XCTAssertEqual(path, linkedAudio.path)
            let date = writer.transcriptsDirectory.appendingPathComponent("2026-09-04")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: date.path).isEmpty)
        }
    }

    func testNonregularAudioAndInvalidMetadataFailWithoutPublishing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = DictationArchiveWriter(root: fixture.root)
        let directoryResult = await writer.save(record: Self.record(), originalAudio: fixture.parent,
                                                transcriptionAudio: fixture.transcription)
        guard case .failure(.unsafePath) = directoryResult else { return XCTFail("A directory is not audio") }
        let invalid = await writer.save(record: Self.record(processingSeconds: .nan), originalAudio: fixture.original,
                                         transcriptionAudio: fixture.transcription)
        guard case .failure(.invalidMetadata) = invalid else { return XCTFail("Nonfinite JSON metadata must fail") }
        let date = writer.transcriptsDirectory.appendingPathComponent("2026-09-04")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: date.path).isEmpty)
    }

    func testPrepareRefusesHomeAndFilesystemRootWithoutChangingThem() async {
        for root in [URL(fileURLWithPath: "/"), FileManager.default.homeDirectoryForCurrentUser] {
            let result = await DictationArchiveWriter(root: root).prepare()
            guard case .failure(.unsafePath) = result else { return XCTFail("Must not change home/root permissions") }
        }
    }

    func testReaderListsNewestTakesWithBoundedPaginationAndAudioAvailability() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = DictationArchiveWriter(root: fixture.root)
        let records = (0..<3).map { Self.record(text: "Take \($0)", id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_788_523_200 + Double($0) * 90_000)) }
        for record in records {
            _ = try await writer.save(record: record, originalAudio: fixture.original, transcriptionAudio: fixture.transcription).get()
        }
        let reader = DictationArchiveReader(directory: writer.transcriptsDirectory)
        let first = try await reader.read(limit: 2).get()
        XCTAssertEqual(first.entries.map(\.record), [records[2], records[1]])
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.skippedCount, 0)
        XCTAssertTrue(first.entries.allSatisfy(\.hasOriginalAudio))
        XCTAssertEqual(first.entries.first?.audioURL.lastPathComponent, "audio.wav")
        let all = try await reader.read(limit: 4).get()
        XCTAssertEqual(all.entries.map(\.record), records.reversed())
        XCTAssertFalse(all.hasMore)
    }

    func testReaderDoesNotCreateAMissingHistoryDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("transcripts")
        let page = try await DictationArchiveReader(directory: directory).read().get()
        XCTAssertTrue(page.entries.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testReaderSkipsCorruptAndLinkedMetadataWithoutLosingValidTakes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = DictationArchiveWriter(root: fixture.root)
        let good = try await writer.save(record: Self.record(), originalAudio: fixture.original,
                                         transcriptionAudio: fixture.transcription).get()
        let metadata = good.appendingPathComponent("metadata.json")
        let original = try Data(contentsOf: metadata)
        let day = good.deletingLastPathComponent()
        for name in ["bad", "linked", ".unfinished"] {
            try FileManager.default.createDirectory(at: day.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        try Data("not json".utf8).write(to: day.appendingPathComponent("bad/metadata.json"))
        try FileManager.default.createSymbolicLink(at: day.appendingPathComponent("linked/metadata.json"), withDestinationURL: metadata)
        try FileManager.default.createSymbolicLink(at: day.appendingPathComponent("linked-take"), withDestinationURL: good)
        let page = try await DictationArchiveReader(directory: writer.transcriptsDirectory).read().get()
        XCTAssertEqual(page.entries.map(\.record), [Self.record()])
        XCTAssertEqual(page.skippedCount, 2)
        XCTAssertEqual(try Data(contentsOf: metadata), original)
    }

    func testReaderRejectsRootLinksAndIgnoresLinkedRecordingsAndMetadataFilenames() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = DictationArchiveWriter(root: fixture.root)
        let folder = try await writer.save(record: Self.record(), originalAudio: fixture.original,
                                           transcriptionAudio: fixture.transcription).get()
        let link = fixture.parent.appendingPathComponent("archive-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: writer.transcriptsDirectory)
        if case .success = await DictationArchiveReader(directory: link).read() { XCTFail("Root symlinks must not be followed") }
        let metadata = folder.appendingPathComponent("metadata.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        var audio = try XCTUnwrap(json["audio"] as? [String: Any])
        audio["originalFilename"] = "../../outside.wav"
        json["audio"] = audio
        try JSONSerialization.data(withJSONObject: json).write(to: metadata)
        let original = folder.appendingPathComponent("audio.wav")
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: fixture.original)
        let page = try await DictationArchiveReader(directory: writer.transcriptsDirectory).read().get()
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(entry.audioURL.lastPathComponent, "audio.wav")
        XCTAssertEqual(entry.audioURL.deletingLastPathComponent().resolvingSymlinksInPath(),
                       folder.resolvingSymlinksInPath())
        XCTAssertFalse(entry.hasOriginalAudio)
        XCTAssertEqual(entry.record.transcriptText, Self.record().transcriptText)
    }

    private static func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }

    private static func record(text: String = "1. Oranges\n2. A trip to the beach",
                               processingSeconds: Double = 0.25,
                               textProcessing: TextProcessingRecord? = nil,
                               id: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                               startedAt: Date = Date(timeIntervalSince1970: 1_788_523_200)) -> DictationArchiveRecord {
        let start = startedAt
        return DictationArchiveRecord(
            id: id,
            startedAt: start, releasedAt: start.addingTimeInterval(4), completedAt: start.addingTimeInterval(5),
            mode: .hotkey, outcome: .transcribed, rawText: "Um, one oranges. Two a trip to the beach.",
            transcriptText: text,
            model: .init(id: "local-model", name: "Local model", sha256: "fixture-sha256",
                         engine: "whisper.cpp", engineVersion: "fixture-revision"),
            options: .init(requestedLanguage: "auto", detectedLanguage: "en", removeFillers: true,
                           vocabularyPrompt: "Sotto, Davis"),
            microphone: .init(uid: "fixture-mic", name: "Fixture microphone"),
            audio: .init(original: .init(sampleRate: 48_000, channels: 2, sampleFormat: "pcm_s16le",
                                         frameCount: 48_000, durationSeconds: 1),
                         transcription: .init(sampleRate: 16_000, channels: 1, sampleFormat: "pcm_s16le",
                                              frameCount: 16_000, durationSeconds: 1)),
            timing: .init(engineProcessingSeconds: processingSeconds, transcriptionWallSeconds: 0.4,
                          releaseToResultSeconds: 1),
            appVersion: "0.6.0", appBuild: "11", deliveryStatus: "inserted", textProcessing: textProcessing)
    }

    private struct Fixture {
        let parent: URL
        let root: URL
        let original: URL
        let transcription: URL

        init() throws {
            parent = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-archive-tests-" + UUID().uuidString,
                                                                                   isDirectory: true)
            root = parent.appendingPathComponent(".murmur", isDirectory: true)
            original = parent.appendingPathComponent("original.wav")
            transcription = parent.appendingPathComponent("input.wav")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o755])
            try Self.wav(sampleRate: 48_000, channels: 2).write(to: original)
            try Self.wav(sampleRate: 16_000, channels: 1).write(to: transcription)
        }

        func remove() { try? FileManager.default.removeItem(at: parent) }

        private static func wav(sampleRate: UInt32, channels: UInt16) -> Data {
            let pcm = Data(repeating: 1, count: Int(sampleRate) * Int(channels) * 2)
            var data = Data("RIFF".utf8)
            func append<T: FixedWidthInteger>(_ number: T) {
                var value = number.littleEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
            append(UInt32(pcm.count + 36))
            data.append(Data("WAVEfmt ".utf8))
            append(UInt32(16))
            append(UInt16(1))
            append(channels)
            append(sampleRate)
            append(sampleRate * UInt32(channels) * 2)
            append(channels * 2)
            append(UInt16(16))
            data.append(Data("data".utf8))
            append(UInt32(pcm.count))
            data.append(pcm)
            return data
        }
    }
}
