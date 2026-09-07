import Foundation
import SottoCore
import XCTest
@testable import Sotto

@MainActor
final class TextCorrectionServiceTests: XCTestCase {
    func testOptOutAndUnavailableModelPreserveTextAndAuditReason() async throws {
        let fixture = try await fixture()
        defer { fixture.service.shutdown(); fixture.config.stopWatching(); try? FileManager.default.removeItem(at: fixture.root) }
        let text = "Use MiniMax and Codex."
        let disabled = try await fixture.service.process(text, dictionary: .default, dictionaryChangedText: true,
                                                        language: "en", enabledForTake: false)
        XCTAssertEqual(disabled.outputText, text)
        XCTAssertEqual(disabled.status, .disabled)
        XCTAssertNil(disabled.modelID)
        XCTAssertTrue(disabled.dictionaryChangedText)
        let missing = try await fixture.service.process(text, dictionary: .default, dictionaryChangedText: false,
                                                       language: "en", enabledForTake: true)
        XCTAssertEqual(missing.outputText, text)
        XCTAssertEqual(missing.status, .unavailable)
        XCTAssertNotNil(missing.reason)
        XCTAssertEqual(fixture.service.engineStatus, .unloaded)
    }

    func testEmptyAndLongTextSkipInferenceWithoutDiscardingTranscript() async throws {
        let fixture = try await fixture()
        defer { fixture.service.shutdown(); fixture.config.stopWatching(); try? FileManager.default.removeItem(at: fixture.root) }
        for text in ["", String(repeating: "a", count: TextCorrectionPolicy.maximumInputCharacters + 1)] {
            let result = try await fixture.service.process(text, dictionary: .default, dictionaryChangedText: false,
                                                          language: "en", enabledForTake: true)
            XCTAssertEqual(result.status, .skipped)
            XCTAssertEqual(result.outputText, text)
        }
        XCTAssertEqual(fixture.service.engineStatus, .unloaded)
    }

    func testAppTogglePersistsAndExternalEditLoadsWithoutWriteback() async throws {
        let fixture = try await fixture()
        defer { fixture.service.shutdown(); fixture.config.stopWatching(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.service.enabled = false
        await fixture.config.flush()
        let saved = try JSONDecoder().decode(SottoConfiguration.self, from: Data(contentsOf: fixture.config.url))
        XCTAssertFalse(saved.textCorrectionEnabled)
        XCTAssertEqual(saved.dictionary, .default)
        var external = saved
        external.textCorrectionEnabled = true
        let bytes = try JSONEncoder().encode(external)
        try bytes.write(to: fixture.config.url, options: .atomic)
        await fixture.config.reload()
        XCTAssertTrue(fixture.service.enabled)
        XCTAssertEqual(try Data(contentsOf: fixture.config.url), bytes)
        XCTAssertEqual(fixture.config.pendingWriteCount, 0)
    }

    func testCancelledTakeDoesNotReturnAFallbackAsACompletedResult() async throws {
        let fixture = try await fixture()
        defer { fixture.service.shutdown(); fixture.config.stopWatching(); try? FileManager.default.removeItem(at: fixture.root) }
        let task = Task {
            try await fixture.service.process("A cancelled take.", dictionary: .default, dictionaryChangedText: false,
                                              language: "en", enabledForTake: false)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError {}
    }

    private func fixture() async throws -> (root: URL, config: ConfigurationStore, service: TextCorrectionService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sotto-correction-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = ConfigurationStore(file: ConfigurationFile(url: root.appendingPathComponent("settings/config.json")),
                                        legacyDefaults: try XCTUnwrap(UserDefaults(suiteName: "Sotto-tests-\(UUID())")))
        await config.start()
        let service = TextCorrectionService(configuration: config,
            client: TextCorrectionClient(modelURL: root.appendingPathComponent("absent-model"), helperURL: root.appendingPathComponent("absent-helper")),
            modelStore: TextModelStore(paths: TextModelPaths(root: root)), inspectOnInit: false)
        return (root, config, service)
    }
}
