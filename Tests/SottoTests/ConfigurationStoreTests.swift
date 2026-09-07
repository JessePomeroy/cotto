import Combine
import Foundation
import SottoCore
import XCTest
@testable import Sotto

final class ConfigurationStoreTests: XCTestCase {
    func testFirstStartMigratesLegacySettingsWithoutDeletingTheBackup() async throws {
        try await withStore { store, file, defaults in
            XCTAssertEqual(store.configuration.holdKey, "fn")
            XCTAssertEqual(store.configuration.language, "es")
            XCTAssertEqual(store.configuration.idleMinutes, 15)
            XCTAssertFalse(store.configuration.cleanText)
            XCTAssertFalse(store.configuration.saveDictationHistory)
            XCTAssertEqual(store.configuration.vocabulary, "Sotto, RØDE")
            XCTAssertTrue(store.configuration.launchAtLogin)
            XCTAssertEqual(store.configuration.microphones.activeProfile.priority.first?.uid, "desk-microphone")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
            XCTAssertFalse(store.isLoaded)

            await store.start()

            XCTAssertTrue(store.isLoaded)
            XCTAssertNil(store.errorMessage)
            let disk = try await file.read().get()
            XCTAssertEqual(disk, store.configuration)
            XCTAssertEqual(defaults.string(forKey: "holdKey"), "fn")
            XCTAssertEqual(defaults.string(forKey: "vocabulary"), "Sotto, RØDE")
            XCTAssertNotNil(defaults.data(forKey: "microphonePreferences.v1"))
        }
    }

    func testMissingAndInvalidLegacyValuesUseSafeDefaults() async throws {
        try await withStore(seedLegacy: false) { store, file, defaults in
            XCTAssertEqual(store.configuration, SottoConfiguration.default)
            defaults.set("not-a-key", forKey: "holdKey")
            defaults.set("not-a-language", forKey: "language")
            defaults.set(123, forKey: "idleMinutes")
            defaults.set(Data("invalid".utf8), forKey: "microphonePreferences.v1")
            let migrated = ConfigurationStore(file: file, legacyDefaults: defaults)
            defer { migrated.stopWatching() }

            await migrated.start()

            XCTAssertEqual(migrated.configuration, SottoConfiguration.default)
            XCTAssertNil(migrated.errorMessage)
        }
    }

    func testExistingJSONWinsOverAllLegacyPreferencesAndRepeatedStartIsIdempotent() async throws {
        try await withStore { store, file, defaults in
            var expected = SottoConfiguration.default
            expected.holdKey = "rightControl"
            expected.language = "ja"
            expected.vocabulary = "From JSON"
            _ = try await file.load(orCreate: expected).get()

            await store.start()
            defaults.set("fr", forKey: "language")
            await store.start()

            XCTAssertEqual(store.configuration, expected)
            let disk = try await file.read().get()
            XCTAssertEqual(disk, expected)
            XCTAssertNil(store.errorMessage)
        }
    }

    func testRapidAppEditsAreOptimisticAndFlushPersistsTheFinalValues() async throws {
        try await withStore(seedLegacy: false) { store, file, _ in
            await store.start()
            for index in 1...40 {
                store.update { $0.vocabulary = "Word \(index)" }
            }
            store.update {
                $0.cleanText = false
                $0.idleMinutes = -1
            }
            XCTAssertEqual(store.configuration.vocabulary, "Word 40")
            XCTAssertEqual(store.configuration.idleMinutes, -1)
            XCTAssertGreaterThan(store.pendingWriteCount, 0)

            await store.flush()

            XCTAssertEqual(store.pendingWriteCount, 0)
            XCTAssertNil(store.errorMessage)
            let disk = try await file.read().get()
            XCTAssertEqual(disk, store.configuration)
            XCTAssertFalse(store.configuration.cleanText)
        }
    }

    func testQueuedAppEditsMergeUnrelatedExternalFieldsAndStartupEdits() async throws {
        try await withStore(seedLegacy: false) { store, file, _ in
            var disk = SottoConfiguration.default
            disk.language = "fr"
            disk.vocabulary = "External vocabulary"
            _ = try await file.load(orCreate: disk).get()
            // An explicit early UI edit does not overwrite untouched fields from JSON.
            store.update { $0.cleanText = false }
            store.update { $0.idleMinutes = 15 }

            await store.flush()

            disk.cleanText = false
            disk.idleMinutes = 15
            XCTAssertEqual(store.configuration, disk)
            let firstSaved = try await file.read().get()
            XCTAssertEqual(firstSaved, disk)

            store.update { $0.holdKey = "fn" }
            disk.language = "ja"
            try Self.write(disk, to: file.url, atomically: true)
            store.update { $0.saveDictationHistory = false }
            await store.flush()

            disk.holdKey = "fn"
            disk.saveDictationHistory = false
            XCTAssertEqual(store.configuration, disk)
            let finalSaved = try await file.read().get()
            XCTAssertEqual(finalSaved, disk)
        }
    }

    func testWatcherReloadsInPlaceWritesAndRepeatedAtomicReplacementsWithoutReSaving() async throws {
        try await withStore(seedLegacy: false) { store, file, _ in
            await store.start()
            var expected = store.configuration
            expected.language = "es"
            try Self.write(expected, to: file.url, atomically: false)
            try await Self.waitUntil { store.configuration == expected }

            expected.language = "de"
            try Self.write(expected, to: file.url, atomically: true)
            try await Self.waitUntil { store.configuration == expected }

            expected.holdKey = "fn"
            try Self.write(expected, to: file.url, atomically: true)
            try await Self.waitUntil { store.configuration == expected }
            let savedDate = try FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date
            try await Task.sleep(for: .milliseconds(400))
            let laterDate = try FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date

            XCTAssertEqual(savedDate, laterDate, "Reloading external edits must not rewrite the config")
            XCTAssertEqual(store.pendingWriteCount, 0)
            XCTAssertNil(store.errorMessage)
        }
    }

    func testInvalidExternalJSONPreservesLastGoodStateAndCannotBeClobberedByAppEdits() async throws {
        try await withStore(seedLegacy: false) { store, file, _ in
            await store.start()
            let valid = store.configuration
            let invalid = Data("{ \"language\": ".utf8)
            try invalid.write(to: file.url)
            try await Self.waitUntil { store.errorMessage != nil }
            XCTAssertEqual(store.configuration, valid)

            store.update { $0.language = "es" }
            await store.flush()
            XCTAssertEqual(try Data(contentsOf: file.url), invalid)
            XCTAssertEqual(store.configuration, valid)
            XCTAssertNotNil(store.errorMessage)

            var repaired = valid
            repaired.language = "fr"
            try Self.write(repaired, to: file.url, atomically: true)
            try await Self.waitUntil { store.configuration == repaired && store.errorMessage == nil }
            XCTAssertEqual(store.pendingWriteCount, 0)
        }
    }

    func testInvalidExistingFileIsNeverReplacedWithMigratedDefaults() async throws {
        try await withStore { store, file, _ in
            let invalid = Data("not JSON".utf8)
            try invalid.write(to: file.url)
            await store.start()
            XCTAssertTrue(store.isLoaded)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.configuration.holdKey, "fn")
            XCTAssertEqual(try Data(contentsOf: file.url), invalid)
        }
    }

    func testExplicitReloadDoesNotRollBackPendingUIEdits() async throws {
        try await withStore(seedLegacy: false) { store, file, _ in
            await store.start()
            var observed: [String] = []
            let subscription = store.$configuration.map(\.vocabulary).removeDuplicates().dropFirst().sink { observed.append($0) }
            defer { subscription.cancel() }
            store.update { $0.vocabulary = "First" }
            let reload = Task { await store.reload() }
            store.update { $0.vocabulary = "Second" }
            store.update { $0.vocabulary = "Final" }
            await reload.value
            await store.flush()

            XCTAssertEqual(store.configuration.vocabulary, "Final")
            let disk = try await file.read().get()
            XCTAssertEqual(disk.vocabulary, "Final")
            XCTAssertEqual(observed, ["First", "Second", "Final"])
        }
    }

    @MainActor
    private func withStore(seedLegacy: Bool = true,
                           _ operation: @MainActor (ConfigurationStore, ConfigurationFile, UserDefaults) async throws -> Void) async throws {
        let suite = "SottoConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = ConfigurationFile(url: root.appendingPathComponent("config.json"))
        if seedLegacy {
            defaults.set("fn", forKey: "holdKey")
            defaults.set("es", forKey: "language")
            defaults.set(15, forKey: "idleMinutes")
            defaults.set(false, forKey: "cleanText")
            defaults.set(false, forKey: "saveDictationHistory")
            defaults.set("Sotto, RØDE", forKey: "vocabulary")
            let microphone = AudioInputDevice(uid: "desk-microphone", name: "Desk microphone", transport: .usb)
            let preferences = MicrophonePreferences(profiles: [.init(id: "desk", name: "Desk", priority: [microphone])])
            defaults.set(try JSONEncoder().encode(preferences), forKey: "microphonePreferences.v1")
        }
        let store = ConfigurationStore(file: file, legacyDefaults: defaults, legacyLoginEnabled: seedLegacy)
        defer {
            store.stopWatching()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try await operation(store, file, defaults)
            await store.flush()
        } catch {
            await store.flush()
            throw error
        }
    }

    private static func write(_ configuration: SottoConfiguration, to url: URL, atomically: Bool) throws {
        let data = try JSONEncoder().encode(configuration)
        if atomically {
            try data.write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
        }
    }

    @MainActor
    private static func waitUntil(_ predicate: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), "Expected configuration update was not observed", file: file, line: line)
    }
}
