import AVFoundation
import Foundation
import SottoCore
import XCTest
@testable import Sotto

final class DictationHistoryStoreTests: XCTestCase {
    func testRetentionDefaultsOnAndPersistsWithoutChangingOtherPreferences() async throws {
        try await withHistory { store, writer, _, fixture in
            XCTAssertTrue(store.isEnabled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.root.path), "Opening the app does not create an empty archive")
            fixture.configuration.update { $0.vocabulary = "Sotto, RØDE" }

            store.isEnabled = false
            await fixture.configuration.flush()
            let restored = ConfigurationStore(file: fixture.file, legacyDefaults: fixture.defaults)
            await restored.start()
            restored.stopWatching()
            let restoredHistory = DictationHistoryStore(configuration: restored, writer: writer)
            XCTAssertFalse(restoredHistory.isEnabled)
            store.isEnabled = true
            await fixture.configuration.flush()
            await restored.reload()
            XCTAssertTrue(restoredHistory.isEnabled)
            XCTAssertEqual(restored.configuration.vocabulary, "Sotto, RØDE")
            XCTAssertNil(fixture.defaults.object(forKey: DictationHistoryStore.enabledKey))
        }
    }

    func testExternalRetentionEditUpdatesExistingStoreWithoutWritingBack() async throws {
        try await withHistory { store, _, _, fixture in
            var external = fixture.configuration.configuration
            external.saveDictationHistory = false
            external.vocabulary = "External words"
            let bytes = try JSONEncoder().encode(external)
            try bytes.write(to: fixture.file.url, options: .atomic)
            await fixture.configuration.reload()

            XCTAssertFalse(store.isEnabled)
            await fixture.configuration.flush()
            XCTAssertEqual(try Data(contentsOf: fixture.file.url), bytes, "External settings must not cause a writeback loop")

            store.isEnabled = true
            await fixture.configuration.flush()
            let saved = try await fixture.file.read().get()
            XCTAssertTrue(saved.saveDictationHistory)
            XCTAssertEqual(saved.vocabulary, "External words")
            XCTAssertEqual(store.pendingSaveCount, 0)
            XCTAssertNil(store.lastError)
        }
    }

    func testFlushPublishesBothAudioFilesBeforeCleaningUpTheCapture() async throws {
        try await withHistory { store, _, _, _ in
            let audio = try await Self.makeAudio()
            defer { audio.cleanup() }
            let original = try XCTUnwrap(audio.original)
            let originalBytes = try Data(contentsOf: original.url)
            let transcriptionBytes = try Data(contentsOf: audio.url)
            let record = Self.makeRecord(audio: audio, original: original)
            let cleanup = HistoryCleanupProbe()
            let archiveDirectory = store.directory

            store.enqueue(record: record, originalAudio: original.url, transcriptionAudio: audio.url,
                          cleanup: { cleanup.observeAndClean(audio, archiveDirectory: archiveDirectory) })
            XCTAssertEqual(store.pendingSaveCount, 1)
            XCTAssertTrue(cleanup.snapshots.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.url.path))
            await store.flush()

            XCTAssertEqual(store.pendingSaveCount, 0)
            XCTAssertNil(store.lastError)
            XCTAssertNotNil(store.lastSavedAt)
            let snapshot = try XCTUnwrap(cleanup.snapshots.only)
            XCTAssertTrue(snapshot.bothSourceFilesExisted)
            XCTAssertTrue(snapshot.archiveWasPublished)
            XCTAssertFalse(snapshot.wasMainThread, "Temporary-file cleanup must not run on the UI thread")
            XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.deletingLastPathComponent().path))

            let metadataURL = try XCTUnwrap(Self.metadataURLs(in: store.directory).only)
            XCTAssertEqual(try Self.readRecord(at: metadataURL), record)
            let folder = metadataURL.deletingLastPathComponent()
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("audio.wav")), originalBytes)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("transcription.wav")), transcriptionBytes)
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8), record.transcriptText)
        }
    }

    func testMultipleQueuedTakesFinishEvenIfRetentionIsTurnedOffAfterEnqueue() async throws {
        try await withHistory { store, _, _, _ in
            let first = try await Self.makeAudio()
            let second = try await Self.makeAudio()
            defer { first.cleanup(); second.cleanup() }
            let firstOriginal = try XCTUnwrap(first.original)
            let secondOriginal = try XCTUnwrap(second.original)
            let firstRecord = Self.makeRecord(audio: first, original: firstOriginal, transcript: "First take")
            let secondRecord = Self.makeRecord(audio: second, original: secondOriginal, transcript: "Second take")

            store.enqueue(record: firstRecord, originalAudio: firstOriginal.url, transcriptionAudio: first.url,
                          cleanup: { first.cleanup() })
            store.enqueue(record: secondRecord, originalAudio: secondOriginal.url, transcriptionAudio: second.url,
                          cleanup: { second.cleanup() })
            XCTAssertEqual(store.pendingSaveCount, 2)
            store.isEnabled = false
            await store.flush()

            let records = try Self.metadataURLs(in: store.directory).map(Self.readRecord)
            XCTAssertEqual(Set(records.map(\.id)), [firstRecord.id, secondRecord.id])
            XCTAssertEqual(Set(records.map(\.transcriptText)), ["First take", "Second take"])
            XCTAssertEqual(store.pendingSaveCount, 0)
            XCTAssertFalse(store.isEnabled)
            XCTAssertNil(store.lastError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
        }
    }

    func testArchiveFailureCleansUpAndRemainsVisibleAfterALaterSuccessfulSave() async throws {
        try await withHistory { store, _, root, _ in
            let audio = try await Self.makeAudio()
            defer { audio.cleanup() }
            let original = try XCTUnwrap(audio.original)
            let cleanup = HistoryCleanupProbe()
            let directory = store.directory
            store.enqueue(record: Self.makeRecord(audio: audio, original: original),
                          originalAudio: root.appendingPathComponent("missing-original.wav"), transcriptionAudio: audio.url,
                          cleanup: { cleanup.observeAndClean(audio, archiveDirectory: directory) })
            await store.flush()

            let saveError = try XCTUnwrap(store.lastError)
            XCTAssertTrue(saveError.contains("not archived"))
            XCTAssertTrue(saveError.contains("discarded"))
            XCTAssertNil(store.lastSavedAt)
            XCTAssertEqual(store.pendingSaveCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.path))
            XCTAssertFalse(try XCTUnwrap(cleanup.snapshots.only).archiveWasPublished)
            XCTAssertTrue(Self.metadataURLs(in: store.directory).isEmpty)

            let recoveredAudio = try await Self.makeAudio()
            defer { recoveredAudio.cleanup() }
            let recoveredOriginal = try XCTUnwrap(recoveredAudio.original)
            store.enqueue(record: Self.makeRecord(audio: recoveredAudio, original: recoveredOriginal),
                          originalAudio: recoveredOriginal.url, transcriptionAudio: recoveredAudio.url,
                          cleanup: { recoveredAudio.cleanup() })
            await store.flush()

            XCTAssertNotNil(store.lastSavedAt)
            XCTAssertEqual(Self.metadataURLs(in: store.directory).count, 1)
            XCTAssertEqual(store.lastError, saveError, "A successful later take must not conceal earlier data loss")
            store.dismissError()
            XCTAssertNil(store.lastError)
        }
    }

    func testContextRetainsPerTakeTextSettingsTimingAndActualAudioFormats() async throws {
        let audio = try await Self.makeAudio()
        defer { audio.cleanup() }
        let original = try XCTUnwrap(audio.original)
        let id = UUID()
        let started = Date(timeIntervalSince1970: 1_788_523_200)
        let context = DictationHistoryContext(
            id: id, startedAt: started, mode: .hotkey,
            microphone: .init(uid: "usb-mic", name: "Desk microphone"), language: "auto",
            prompt: "Sotto, RØDE", removeFillers: false
        )
        let result = TranscriptionResult(text: "Um, next item, oranges.", audioSeconds: 999,
                                         processingSeconds: 0.18, language: "en")
        let record = context.record(
            audio: audio, original: original, releasedAt: started.addingTimeInterval(1),
            completedAt: started.addingTimeInterval(1.5), outcome: .transcribed, result: result,
            transcript: "3. oranges", transcriptionWallSeconds: 0.35, releaseToResultSeconds: 0.5,
            deliveryStatus: .copied, errorMessage: nil, engineVersion: "1.9.3-dev"
        )

        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.startedAt, started)
        XCTAssertEqual(record.releasedAt, started.addingTimeInterval(1))
        XCTAssertEqual(record.completedAt, started.addingTimeInterval(1.5))
        XCTAssertEqual(record.mode, .hotkey)
        XCTAssertEqual(record.outcome, .transcribed)
        XCTAssertEqual(record.rawText, result.text)
        XCTAssertEqual(record.transcriptText, "3. oranges", "Archive the current take, not the combined list preview")
        XCTAssertEqual(record.options.requestedLanguage, "auto")
        XCTAssertEqual(record.options.detectedLanguage, "en")
        XCTAssertEqual(record.options.vocabularyPrompt, "Sotto, RØDE")
        XCTAssertFalse(record.options.removeFillers)
        XCTAssertEqual(record.microphone, context.microphone)
        XCTAssertEqual(record.model.id, SpeechModel.turbo.id)
        XCTAssertEqual(record.model.sha256, SpeechModel.turbo.sha256)
        XCTAssertEqual(record.model.engineVersion, "1.9.3-dev")
        XCTAssertEqual(record.audio.original.sampleRate, 48_000)
        XCTAssertEqual(record.audio.original.channels, 2)
        XCTAssertEqual(record.audio.original.frameCount, 4_800)
        XCTAssertEqual(record.audio.original.sampleFormat, "pcm_f32le")
        XCTAssertEqual(record.audio.original.durationSeconds, 0.1)
        XCTAssertEqual(record.audio.transcription.sampleRate, 16_000)
        XCTAssertEqual(record.audio.transcription.channels, 1)
        XCTAssertEqual(record.audio.transcription.frameCount, try AVAudioFile(forReading: audio.url).length)
        XCTAssertEqual(record.audio.transcription.durationSeconds, audio.duration, "Audio metadata describes the actual WAV, not the engine's estimate")
        XCTAssertEqual(record.timing.engineProcessingSeconds, 0.18)
        XCTAssertEqual(record.timing.transcriptionWallSeconds, 0.35)
        XCTAssertEqual(record.timing.releaseToResultSeconds, 0.5)
        XCTAssertEqual(record.deliveryStatus, "copied")
        XCTAssertNil(record.errorMessage)

        let failure = context.record(
            audio: audio, original: original, releasedAt: started.addingTimeInterval(1),
            completedAt: started.addingTimeInterval(2), outcome: .failed, result: nil,
            transcript: "", transcriptionWallSeconds: 1, releaseToResultSeconds: 1,
            deliveryStatus: nil, errorMessage: "Engine stopped"
        )
        XCTAssertEqual(failure.outcome, .failed)
        XCTAssertEqual(failure.model.engineVersion, "unknown")
        XCTAssertEqual(failure.rawText, "")
        XCTAssertEqual(failure.transcriptText, "")
        XCTAssertNil(failure.options.detectedLanguage)
        XCTAssertNil(failure.timing.engineProcessingSeconds)
        XCTAssertNil(failure.deliveryStatus)
        XCTAssertEqual(failure.errorMessage, "Engine stopped")
    }

    @MainActor
    private func withHistory(_ operation: @MainActor (DictationHistoryStore, DictationArchiveWriter, URL, HistoryConfigurationFixture) async throws -> Void) async throws {
        let suite = "SottoHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let writer = DictationArchiveWriter(root: root.appendingPathComponent("archive", isDirectory: true))
        let file = ConfigurationFile(url: root.appendingPathComponent("config.json"))
        let configuration = ConfigurationStore(file: file, legacyDefaults: defaults)
        await configuration.start()
        configuration.stopWatching()
        let fixture = HistoryConfigurationFixture(configuration: configuration, file: file, defaults: defaults)
        let store = DictationHistoryStore(configuration: configuration, writer: writer)
        do { try await operation(store, writer, root, fixture) }
        catch {
            await store.flush()
            await configuration.flush()
            throw error
        }
        await store.flush()
        await configuration.flush()
    }

    private static func makeAudio() async throws -> CapturedAudio {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let channels = try XCTUnwrap(buffer.floatChannelData)
        channels[0].initialize(repeating: 0.2, count: 4_800)
        channels[1].initialize(repeating: -0.1, count: 4_800)
        let writer = try RecordingWriter(inputFormat: format, preserveOriginalAudio: true, onLevel: { _ in }, onError: { _ in })
        writer.append(buffer)
        return try await writer.finish()
    }

    private static func makeRecord(audio: CapturedAudio, original: OriginalCapturedAudio, transcript: String = "3. oranges") -> DictationArchiveRecord {
        let started = Date(timeIntervalSince1970: 1_788_523_200)
        return DictationHistoryContext(
            id: UUID(), startedAt: started, mode: .test, microphone: .init(uid: "test-input", name: "Generated PCM"),
            language: "en", prompt: "", removeFillers: true
        ).record(audio: audio, original: original, releasedAt: started.addingTimeInterval(0.25),
                 completedAt: started.addingTimeInterval(0.5), outcome: .transcribed,
                 result: TranscriptionResult(text: "Next item, oranges.", audioSeconds: audio.duration, processingSeconds: 0.15, language: "en"),
                 transcript: transcript, transcriptionWallSeconds: 0.2, releaseToResultSeconds: 0.3,
                 deliveryStatus: .tested, errorMessage: nil)
    }

    private static func metadataURLs(in directory: URL) -> [URL] {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "metadata.json" }
    }

    private static func readRecord(at url: URL) throws -> DictationArchiveRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid archive timestamp")
            }
            return date
        }
        return try decoder.decode(DictationArchiveRecord.self, from: Data(contentsOf: url))
    }
}

private struct HistoryConfigurationFixture {
    let configuration: ConfigurationStore
    let file: ConfigurationFile
    let defaults: UserDefaults
}

private final class HistoryCleanupProbe: @unchecked Sendable {
    struct Snapshot {
        let bothSourceFilesExisted: Bool
        let archiveWasPublished: Bool
        let wasMainThread: Bool
    }

    private let lock = NSLock()
    private var observed: [Snapshot] = []
    var snapshots: [Snapshot] { lock.withLock { observed } }

    func observeAndClean(_ audio: CapturedAudio, archiveDirectory: URL) {
        let files = FileManager.default
        let hasSources = files.fileExists(atPath: audio.url.path)
            && audio.original.map { files.fileExists(atPath: $0.url.path) } == true
        let entries = files.enumerator(at: archiveDirectory, includingPropertiesForKeys: nil)
        let hasArchive = entries?.contains { ($0 as? URL)?.lastPathComponent == "metadata.json" } ?? false
        let snapshot = Snapshot(bothSourceFilesExisted: hasSources, archiveWasPublished: hasArchive, wasMainThread: Thread.isMainThread)
        audio.cleanup()
        lock.withLock { observed.append(snapshot) }
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
