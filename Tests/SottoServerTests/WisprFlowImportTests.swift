import CryptoKit
import Foundation
import SottoAPI
@testable import SottoServerKit
import XCTest

final class WisprFlowImportTests: XCTestCase {
    func testRerunBackfillsAudioIntoTheSameDurableHistoryRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let source = Self.sourceJSON(for: sourceID)
        let wav = Self.smallWAV
        let service = try GenerationService(configuration: fixture.configuration)

        let first = try await service.beginWisprFlowImport(Self.request(sourceID: sourceID, text: "Recovered text", artifacts: [(.sourceJSON, source)]))
        _ = try await service.uploadWisprFlowArtifact(first.id, filename: .sourceJSON, data: source)
        let imported = try await service.completeWisprFlowImport(first.id)
        XCTAssertEqual(imported.outcome, .imported)
        XCTAssertEqual(imported.record.finalText, "Recovered text")
        XCTAssertEqual(imported.record.importedSource?.sourceID, sourceID)
        await service.shutdown()

        let restarted = try GenerationService(configuration: fixture.configuration)
        let second = try await restarted.beginWisprFlowImport(Self.request(sourceID: sourceID, text: "Recovered text", artifacts: [(.sourceJSON, source), (.sourceWAV, wav)]))
        _ = try await restarted.uploadWisprFlowArtifact(second.id, filename: .sourceJSON, data: source)
        _ = try await restarted.uploadWisprFlowArtifact(second.id, filename: .sourceWAV, data: wav)
        let enriched = try await restarted.completeWisprFlowImport(second.id)
        XCTAssertEqual(enriched.outcome, .enriched)
        XCTAssertEqual(enriched.record.id, imported.record.id)
        XCTAssertEqual(enriched.record.importedSource?.artifactNames.contains(.sourceWAV), true)
        let archivedWAV = try await restarted.artifact(imported.record.id, filename: "source.wav")
        XCTAssertEqual(try Data(contentsOf: archivedWAV), wav)
        let history = try await restarted.history(limit: 50, before: nil, source: "wispr-flow")
        XCTAssertEqual(history.items.map(\.id), [imported.record.id])
        let known = try await restarted.knownWisprFlowIDs(.init(sourceIDs: [sourceID, UUID()]))
        XCTAssertEqual(known.knownSourceIDs, [sourceID])
        await restarted.shutdown()

        let afterBackfill = try GenerationService(configuration: fixture.configuration)
        let durable = try await afterBackfill.get(imported.record.id)
        XCTAssertEqual(durable.importedSource?.sourceID, sourceID)
        XCTAssertEqual(durable.finalText, "Recovered text")
        XCTAssertEqual(durable.importedSource?.artifactSHA256["source.wav"], Self.sha256(wav))
        let durableWAV = try await afterBackfill.artifact(imported.record.id, filename: "source.wav")
        XCTAssertEqual(try Data(contentsOf: durableWAV), wav)
        await afterBackfill.shutdown()
    }

    func testMetadataOnlyAttemptIsArchivedWithoutInventingATranscript() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let source = Self.sourceJSON(for: sourceID)
        let service = try GenerationService(configuration: fixture.configuration)
        let request = Self.request(sourceID: sourceID, text: "", status: "FAILED", artifacts: [(.sourceJSON, source)])
        let session = try await service.beginWisprFlowImport(request)
        _ = try await service.uploadWisprFlowArtifact(session.id, filename: .sourceJSON, data: source)
        let result = try await service.completeWisprFlowImport(session.id)
        XCTAssertEqual(result.outcome, .imported)
        XCTAssertTrue(result.record.finalText.isEmpty)
        XCTAssertTrue(result.record.rawText.isEmpty)
        XCTAssertEqual(result.record.importedSource?.sourceStatus, "FAILED")
        XCTAssertNil(result.record.inferenceAudio)
        XCTAssertNil(result.record.originalAudio)
        await service.shutdown()
    }

    func testConflictingNewMediaKeepsEarlierBytesWhileEnrichingText() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let originalSource = Self.sourceJSON(for: sourceID)
        let newerSource = Self.sourceJSON(for: sourceID, version: 2)
        let originalWAV = Self.smallWAV
        var conflictingWAV = originalWAV
        conflictingWAV[conflictingWAV.count - 1] = 1
        let service = try GenerationService(configuration: fixture.configuration)

        let first = try await service.beginWisprFlowImport(Self.request(sourceID: sourceID, text: "First text", artifacts: [(.sourceJSON, originalSource), (.sourceWAV, originalWAV)]))
        _ = try await service.uploadWisprFlowArtifact(first.id, filename: .sourceJSON, data: originalSource)
        _ = try await service.uploadWisprFlowArtifact(first.id, filename: .sourceWAV, data: originalWAV)
        let imported = try await service.completeWisprFlowImport(first.id)

        let second = try await service.beginWisprFlowImport(Self.request(sourceID: sourceID, text: "Corrected text", artifacts: [(.sourceJSON, newerSource), (.sourceWAV, conflictingWAV)]))
        _ = try await service.uploadWisprFlowArtifact(second.id, filename: .sourceJSON, data: newerSource)
        _ = try await service.uploadWisprFlowArtifact(second.id, filename: .sourceWAV, data: conflictingWAV)
        let enriched = try await service.completeWisprFlowImport(second.id)
        XCTAssertEqual(enriched.outcome, .partial)
        XCTAssertEqual(enriched.unarchivedArtifactNames, [.sourceWAV])
        XCTAssertEqual(enriched.record.id, imported.record.id)
        XCTAssertEqual(enriched.record.finalText, "Corrected text")
        XCTAssertEqual(enriched.record.importedSource?.artifactSHA256["source.wav"], Self.sha256(originalWAV))
        XCTAssertEqual(enriched.record.importedSource?.unarchivedArtifactSHA256?["source.wav"], Self.sha256(conflictingWAV))
        let archivedWAV = try await service.artifact(imported.record.id, filename: "source.wav")
        XCTAssertEqual(try Data(contentsOf: archivedWAV), originalWAV)
        let sourceArtifact = try await service.artifact(imported.record.id, filename: "source.json")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sourceArtifact)) as? [String: Any])
        let conflicts = try XCTUnwrap(document["archiveConflicts"] as? [[String: Any]])
        XCTAssertEqual(conflicts.first?["status"] as? String, "not-archived")
        XCTAssertEqual(conflicts.first?["observedSHA256"] as? String, Self.sha256(conflictingWAV))
        await service.shutdown()
    }

    func testMalformedArtifactCannotCreateAnImportedRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let source = Self.sourceJSON(for: sourceID)
        let malformedWAV = Data("not a WAV file".utf8)
        let service = try GenerationService(configuration: fixture.configuration)
        let request = Self.request(sourceID: sourceID, text: "Test", artifacts: [(.sourceJSON, source), (.sourceWAV, malformedWAV)])
        let session = try await service.beginWisprFlowImport(request)
        _ = try await service.uploadWisprFlowArtifact(session.id, filename: .sourceJSON, data: source)
        do {
            _ = try await service.uploadWisprFlowArtifact(session.id, filename: .sourceWAV, data: malformedWAV)
            _ = try await service.completeWisprFlowImport(session.id)
            XCTFail("An invalid WAV must be rejected before it enters history.")
        } catch let error as ServiceError {
            XCTAssertEqual(error.status, 400)
        }
        let known = try await service.knownWisprFlowIDs(.init(sourceIDs: [sourceID]))
        XCTAssertTrue(known.knownSourceIDs.isEmpty)
        await service.shutdown()
    }

    private static func request(sourceID: UUID, text: String, status: String? = "COMPLETED",
                                artifacts: [(WisprFlowArtifactName, Data)]) -> WisprFlowImportRequest {
        WisprFlowImportRequest(sourceID: sourceID, createdAt: Date(timeIntervalSince1970: 1_767_441_600),
            sourceStatus: status, finalText: text, rawText: text, durationSeconds: text.isEmpty ? nil : 1.25,
            variantNames: text.isEmpty ? [] : ["pastedText"],
            artifacts: artifacts.map { name, data in
                WisprFlowArtifactManifest(filename: name, byteCount: data.count, sha256: sha256(data))
            })
    }

    private static func sourceJSON(for id: UUID, version: Int = 0) -> Data {
        let sources = version == 0 ? "[]" : "[{\"syntheticVersion\":\(version)}]"
        return Data(#"{"schemaVersion":1,"provider":"wispr-flow","sourceID":"\#(id.uuidString.lowercased())","sources":\#(sources)}"#.utf8)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let smallWAV = Data([0x52, 0x49, 0x46, 0x46, 0x26, 0, 0, 0, 0x57, 0x41, 0x56, 0x45,
                                        0x66, 0x6d, 0x74, 0x20, 0x10, 0, 0, 0, 1, 0, 1, 0,
                                        0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0,
                                        0x64, 0x61, 0x74, 0x61, 2, 0, 0, 0, 0, 0])

    private struct Fixture {
        let directory: URL
        let configuration: ServerConfiguration

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-flow-import-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let unused = directory.appendingPathComponent("unused-model")
            let inference = InferenceConfiguration(speechHelper: unused, speechModel: unused, vadModel: unused,
                                                   proofHelper: unused, proofModel: unused)
            configuration = try ServerConfiguration(dataDirectory: directory.appendingPathComponent("state"),
                                                    development: true, inference: inference)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
