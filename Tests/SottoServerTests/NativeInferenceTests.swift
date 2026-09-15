import Foundation
import XCTest
@testable import SottoServerKit

final class NativeInferenceTests: XCTestCase {
    func testWarmHelpersServeBothProtocolsAndSurviveIdleCancellation() async throws {
        let fixture = try Fixture(body: """
        printf '{"type":"ready","engineVersion":"fixture-1"}\\n'
        while IFS= read -r line; do
            id=$(printf '%s' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
            printf '{"type":"progress","id":"%s","value":0.5}\\n' "$id"
            printf '{"type":"result","id":"%s","text":"Hello world.","duration":2,"elapsed":0.1,"language":"en"}\\n' "$id"
        done
        """)
        defer { fixture.remove() }
        let inference = NativeInference(configuration: fixture.configuration())
        try await inference.warmUp()
        await inference.cancel()
        let ready = await inference.readiness()
        XCTAssertTrue(ready.available)
        XCTAssertTrue(ready.speechLoaded)
        XCTAssertTrue(ready.proofLoaded)
        let speech = try await inference.transcribe(fixture.model, language: "en", prompt: "")
        XCTAssertEqual(speech.text, "Hello world.")
        XCTAssertEqual(speech.audioSeconds, 2)
        XCTAssertEqual(speech.engineVersion, "fixture-1")
        let corrected = try await inference.correct(speech.text, terms: ["Sotto"], language: "en")
        XCTAssertEqual(corrected.text, "Hello world.")
        XCTAssertEqual(corrected.engineVersion, "fixture-1")
        await inference.shutdown()
    }

    func testInferenceDeadlineResetsProcess() async throws {
        let fixture = try Fixture(body: """
        printf '{"type":"ready"}\\n'
        IFS= read -r line
        exec /bin/sleep 30
        """)
        defer { fixture.remove() }
        let inference = NativeInference(configuration: fixture.configuration(inferenceTimeout: 0.1))
        do {
            _ = try await inference.transcribe(fixture.model, language: "en", prompt: "")
            XCTFail("A helper that never responds must time out.")
        } catch InferenceError.timeout { }
        let state = await inference.readiness(proofreadingEnabled: false)
        XCTAssertFalse(state.speechLoaded)
        await inference.shutdown()
    }

    func testLoadingDeadlineResolvesWaiter() async throws {
        let fixture = try Fixture(body: "exec /bin/sleep 30")
        defer { fixture.remove() }
        let inference = NativeInference(configuration: fixture.configuration(loadTimeout: 0.1))
        do {
            try await inference.warmUp(proofreadingEnabled: false)
            XCTFail("A helper that never becomes ready must time out.")
        } catch InferenceError.timeout { }
        let state = await inference.readiness(proofreadingEnabled: false)
        XCTAssertFalse(state.speechLoaded)
        await inference.shutdown()
    }

    func testTaskCancellationKillsActiveHelperAndResolvesRequest() async throws {
        let fixture = try Fixture(body: """
        printf '{"type":"ready"}\\n'
        IFS= read -r line
        exec /bin/sleep 30
        """)
        defer { fixture.remove() }
        let inference = NativeInference(configuration: fixture.configuration())
        try await inference.warmUp(proofreadingEnabled: false)
        let request = Task { try await inference.transcribe(fixture.model, language: "en", prompt: "") }
        try await Task.sleep(nanoseconds: 50_000_000)
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Cancelling the inference task must resolve it.")
        } catch InferenceError.cancelled { }
        catch is CancellationError { }
        let state = await inference.readiness(proofreadingEnabled: false)
        XCTAssertFalse(state.speechLoaded)
        await inference.shutdown()
    }

    func testOversizedProtocolLineIsRejected() async throws {
        let fixture = try Fixture(body: """
        printf '{"type":"ready"}\\n'
        IFS= read -r line
        awk 'BEGIN { for (i = 0; i < 70000; i++) printf "x"; printf "\\n" }'
        exec /bin/sleep 30
        """)
        defer { fixture.remove() }
        let inference = NativeInference(configuration: fixture.configuration())
        do {
            _ = try await inference.correct("Hello.", terms: [], language: "en")
            XCTFail("Oversized output must not reach the JSON decoder.")
        } catch InferenceError.unavailable(let message) {
            XCTAssertTrue(message.contains("size limit"))
        }
        await inference.shutdown()
    }

    func testMissingProofAssetsDoNotBlockSpeechOnlyReadiness() async throws {
        let fixture = try Fixture(body: "exit 0")
        defer { fixture.remove() }
        var config = fixture.configuration()
        config.proofModel = fixture.directory.appendingPathComponent("missing-proof")
        let inference = NativeInference(configuration: config)
        let speech = await inference.readiness(proofreadingEnabled: false)
        let proof = await inference.readiness(proofreadingEnabled: true)
        XCTAssertTrue(speech.available)
        XCTAssertFalse(proof.available)
        await inference.shutdown()
    }

    func testModelVerificationRejectsTamperingAfterWarmup() async throws {
        let fixture = try Fixture(body: """
        printf '{"type":"ready"}\\n'
        while IFS= read -r line; do :; done
        """)
        defer { fixture.remove() }
        var config = fixture.configuration()
        config.modelVerification = .fixture(
            speechSHA256: "c7a3a8c7435ef8e4cf1ca2d261f7e09ca85de6cdb70f7c689a836680523a180c",
            proofSHA256: nil
        )
        let inference = NativeInference(configuration: config)
        let unchecked = await inference.readiness(proofreadingEnabled: false)
        XCTAssertFalse(unchecked.available)
        try await inference.warmUp(proofreadingEnabled: false)
        let checked = await inference.readiness(proofreadingEnabled: false)
        XCTAssertTrue(checked.available)
        // Same length defeats a size-only cache, but inode/timestamp binding
        // invalidates the verified digest and forces the edited file to be hashed.
        try Data("altered model".utf8).write(to: fixture.model)
        let tampered = await inference.readiness(proofreadingEnabled: false)
        XCTAssertFalse(tampered.available)
        do {
            try await inference.warmUp(proofreadingEnabled: false)
            XCTFail("A model changed after successful verification must be rejected.")
        } catch InferenceError.unavailable(let message) {
            XCTAssertTrue(message.contains("SHA-256"))
        }
        await inference.shutdown()
    }

    private struct Fixture {
        let directory: URL
        let executable: URL
        let model: URL

        init(body: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-inference-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            executable = directory.appendingPathComponent("helper")
            model = directory.appendingPathComponent("model")
            try Data("fixture model".utf8).write(to: model)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func configuration(loadTimeout: Double = 3, inferenceTimeout: Double = 3) -> InferenceConfiguration {
            var config = InferenceConfiguration(speechHelper: executable, speechModel: model, vadModel: model,
                                   proofHelper: executable, proofModel: model,
                                   speechLoadTimeout: loadTimeout, speechTimeout: inferenceTimeout,
                                   proofLoadTimeout: loadTimeout, proofTimeout: inferenceTimeout)
            config.modelVerification = .fixture(speechSHA256: nil, proofSHA256: nil)
            return config
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
