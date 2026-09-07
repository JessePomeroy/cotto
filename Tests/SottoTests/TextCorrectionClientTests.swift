import Darwin
import Foundation
import SottoCore
import XCTest
@testable import Sotto

@MainActor
final class TextCorrectionClientTests: XCTestCase {
    func testConcurrentCallersShareOneLoadAndSmallReadyLinesArriveImmediately() async throws {
        let fixture = try FakeTextEngineFixture()
        let engine = fixture.makeClient()
        defer { engine.unload(); fixture.cleanup() }
        var outcomes: [Result<Void, Error>] = []
        for _ in 0..<6 {
            Task {
                do { try await engine.ensureLoaded(); outcomes.append(.success(())) }
                catch { outcomes.append(.failure(error)) }
            }
        }
        try await waitUntil { fixture.startedProcesses.count == 1 }
        try fixture.allowReady(1)
        try await waitUntil { outcomes.count == 6 }
        XCTAssertEqual(fixture.startedProcesses.count, 1)
        XCTAssertEqual(engine.status, .ready)
        XCTAssertEqual(engine.engineVersion, "fixture-engine-version")
        for outcome in outcomes { try outcome.get() }
    }

    func testUnloadResolvesEveryCallerWaitingForLoad() async throws {
        let fixture = try FakeTextEngineFixture()
        let engine = fixture.makeClient()
        defer { engine.unload(); fixture.cleanup() }
        var outcomes: [Result<Void, Error>] = []
        for _ in 0..<4 {
            Task {
                do { try await engine.ensureLoaded(); outcomes.append(.success(())) }
                catch { outcomes.append(.failure(error)) }
            }
        }
        try await waitUntil { fixture.startedProcesses.count == 1 }
        engine.unload()
        try await waitUntil { outcomes.count == 4 }
        XCTAssertEqual(engine.status, .unloaded)
        XCTAssertNil(engine.processIdentifier)
        for outcome in outcomes {
            guard case .failure(let error) = outcome, case TextCorrectionError.cancelled = error else {
                return XCTFail("Every shared loading waiter must resolve as cancelled")
            }
        }
    }

    func testAlreadyCancelledLoadDoesNotLaunchAProcess() async throws {
        let fixture = try FakeTextEngineFixture()
        let engine = fixture.makeClient()
        defer { engine.unload(); fixture.cleanup() }
        var outcome: Result<Void, Error>?
        let caller = Task {
            do { try await engine.ensureLoaded(); outcome = .success(()) }
            catch { outcome = .failure(error) }
        }
        // The test and task share MainActor; the task has not run before cancel().
        caller.cancel()
        try await waitUntil { outcome != nil }
        guard case .failure(let error) = outcome else { return XCTFail("The cancelled load unexpectedly succeeded") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(fixture.startedProcesses.count, 0)
        XCTAssertEqual(engine.status, .unloaded)
    }

    func testCancellingATakeKeepsTheReadyModelForTheNextTranscription() async throws {
        let fixture = try FakeTextEngineFixture()
        let engine = fixture.makeClient()
        defer { engine.unload(); fixture.cleanup() }
        try await load(engine, fixture: fixture, number: 1)
        let originalPID = engine.processIdentifier

        engine.cancelCurrentOperation()
        XCTAssertEqual(engine.status, .ready)
        XCTAssertEqual(engine.processIdentifier, originalPID)

        try fixture.allowResult(1)
        let result = try await engine.correct("dictation fixture", terms: [], language: "en")
        XCTAssertEqual(result.text, "reply-1")
        XCTAssertEqual(fixture.startedProcesses.count, 1, "A brief cancelled hold must not force a model reload")
    }

    func testUnloadResolvesInFlightCorrection() async throws {
        let fixture = try FakeTextEngineFixture()
        let engine = fixture.makeClient()
        defer { engine.unload(); fixture.cleanup() }
        try await load(engine, fixture: fixture, number: 1)
        var outcome: Result<TextCorrectionResult, Error>?
        Task {
            do { outcome = .success(try await engine.correct("dictation fixture", terms: [], language: "en")) }
            catch { outcome = .failure(error) }
        }
        try await waitUntil { fixture.exists("received-1") }
        XCTAssertEqual(engine.status, .transcribing)
        engine.unload()
        try await waitUntil { outcome != nil }
        guard case .failure(let error) = outcome, case TextCorrectionError.cancelled = error else {
            return XCTFail("Unloading must resolve the correction continuation")
        }
        XCTAssertEqual(engine.status, .unloaded)
    }

    func testOldProcessReadyCannotCompleteNewProcessLoad() async throws {
        let fixture = try FakeTextEngineFixture(ignoreTermination: true)
        let engine = fixture.makeClient()
        defer { engine.unload(); fixture.cleanup() }
        var oldOutcome: Result<Void, Error>?
        Task {
            do { try await engine.ensureLoaded(); oldOutcome = .success(()) }
            catch { oldOutcome = .failure(error) }
        }
        try await waitUntil { fixture.startedProcesses.count == 1 }
        engine.unload()
        try await waitUntil { oldOutcome != nil }

        var newOutcome: Result<Void, Error>?
        Task {
            do { try await engine.ensureLoaded(); newOutcome = .success(()) }
            catch { newOutcome = .failure(error) }
        }
        try await waitUntil { fixture.startedProcesses.count == 2 }
        let newPID = engine.processIdentifier
        try fixture.allowReady(1)
        try await waitUntil { fixture.exists("ready-sent-1") }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(newOutcome)
        XCTAssertEqual(engine.status, .loading)
        XCTAssertEqual(engine.processIdentifier, newPID)
        try fixture.allowReady(2)
        try await waitUntil { newOutcome != nil }
        try XCTUnwrap(newOutcome).get()
        XCTAssertEqual(engine.status, .ready)
    }

    func testLateOldResultAndErrorCannotCorruptNewGeneration() async throws {
        let fixture = try FakeTextEngineFixture(ignoreTermination: true)
        let engine = fixture.makeClient()
        defer { engine.unload(); fixture.cleanup() }
        try fixture.touch("send-error-1")
        try await load(engine, fixture: fixture, number: 1)
        var oldOutcome: Result<TextCorrectionResult, Error>?
        Task {
            do { oldOutcome = .success(try await engine.correct("dictation fixture", terms: [], language: "en")) }
            catch { oldOutcome = .failure(error) }
        }
        try await waitUntil { fixture.exists("received-1") }
        engine.unload()
        try await waitUntil { oldOutcome != nil }

        var loadOutcome: Result<Void, Error>?
        Task {
            do { try await engine.ensureLoaded(); loadOutcome = .success(()) }
            catch { loadOutcome = .failure(error) }
        }
        try await waitUntil { fixture.startedProcesses.count == 2 }
        let newPID = engine.processIdentifier
        try fixture.allowResult(1)
        try await waitUntil { fixture.exists("result-sent-1") }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(loadOutcome)
        XCTAssertEqual(engine.status, .loading)
        XCTAssertEqual(engine.processIdentifier, newPID)

        try fixture.allowReady(2)
        try await waitUntil { loadOutcome != nil }
        try XCTUnwrap(loadOutcome).get()
        var newOutcome: Result<TextCorrectionResult, Error>?
        Task {
            do { newOutcome = .success(try await engine.correct("dictation fixture", terms: [], language: "en")) }
            catch { newOutcome = .failure(error) }
        }
        try fixture.allowResult(2)
        try await waitUntil { newOutcome != nil }
        XCTAssertEqual(try XCTUnwrap(newOutcome).get().text, "reply-2")
        XCTAssertEqual(engine.status, .ready)
    }

    func testTaskCancellationResolvesInFlightCorrectionWithoutExplicitUnload() async throws {
        let fixture = try FakeTextEngineFixture()
        let engine = fixture.makeClient()
        defer { engine.unload(); fixture.cleanup() }
        try await load(engine, fixture: fixture, number: 1)
        var outcome: Result<TextCorrectionResult, Error>?
        let task = Task {
            do { outcome = .success(try await engine.correct("dictation fixture", terms: [], language: "en")) }
            catch { outcome = .failure(error) }
        }
        try await waitUntil { fixture.exists("received-1") }
        task.cancel()
        try await waitUntil { outcome != nil }
        guard case .failure = outcome else { return XCTFail("Cancelled correction must not return a result") }
        XCTAssertEqual(engine.status, .unloaded)
        XCTAssertNil(engine.processIdentifier)
    }

    func testShortTimeoutResetsHungHelper() async throws {
        let fixture = try FakeTextEngineFixture()
        let engine = TextCorrectionClient(modelURL: fixture.model, helperURL: fixture.helper,
                                          loadTimeout: 2, correctionTimeout: 0.05)
        defer { engine.unload(); fixture.cleanup() }
        try await load(engine, fixture: fixture, number: 1)
        do {
            _ = try await engine.correct("dictation fixture", terms: [], language: "en")
            XCTFail("The fixture never sends a result")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("too long"))
        }
        XCTAssertEqual(engine.status, .failed)
        XCTAssertNil(engine.processIdentifier)
    }

    func testQueuedOldCancellationCannotCancelANewWarmup() async throws {
        let fixture = try FakeTextEngineFixture()
        let engine = fixture.makeClient()
        defer { engine.unload(); fixture.cleanup() }
        try await load(engine, fixture: fixture, number: 1)
        let oldTake = Task {
            try? await engine.correct("dictation fixture", terms: [], language: "en")
        }
        try await waitUntil { fixture.exists("received-1") }
        try fixture.allowReady(2)
        oldTake.cancel()
        engine.unload()
        // Starts the replacement load before the queued MainActor cancellation
        // handler runs. Its obsolete operation ID must not cancel this load.
        try await engine.ensureLoaded()
        XCTAssertEqual(engine.status, .ready)
        XCTAssertEqual(fixture.startedProcesses.count, 2)
    }

    func testOversizedInputDoesNotLoadModel() async throws {
        let fixture = try FakeTextEngineFixture()
        let engine = fixture.makeClient()
        defer { engine.unload(); fixture.cleanup() }
        for text in [String(repeating: "a", count: 25 * 1024), String(repeating: "\u{0001}", count: 12 * 1024)] {
            do {
                _ = try await engine.correct(text, terms: [], language: "en")
                XCTFail("Oversized raw or JSON-escaped input must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("limit"))
            }
        }
        XCTAssertEqual(fixture.startedProcesses.count, 0)
        XCTAssertEqual(engine.status, .unloaded)
    }

    private func load(_ engine: TextCorrectionClient, fixture: FakeTextEngineFixture, number: Int) async throws {
        try fixture.allowReady(number)
        var outcome: Result<Void, Error>?
        Task {
            do { try await engine.ensureLoaded(); outcome = .success(()) }
            catch { outcome = .failure(error) }
        }
        try await waitUntil { outcome != nil }
        try XCTUnwrap(outcome).get()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw FakeTextEngineError.timedOut
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum FakeTextEngineError: Error {
    case timedOut
}

/// Real pipes and processes, but no microphone, model, network, or user settings.
@MainActor
private struct FakeTextEngineFixture {
    let root: URL
    let helper: URL
    let model: URL

    init(ignoreTermination: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Sotto-text-engine-test-\(UUID().uuidString)", isDirectory: true)
        helper = root.appendingPathComponent("fake-engine.sh")
        model = root.appendingPathComponent("model.gguf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("model fixture".utf8).write(to: model)
        let quotedRoot = "'" + root.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = #"""
        #!/bin/sh
        set -eu
        fixture=\#(quotedRoot)
        if [ -f "$fixture/ignore-termination" ]; then trap '' TERM; fi
        printf '%s\n' "$$" >> "$fixture/starts"
        number=$(/usr/bin/wc -l < "$fixture/starts" | /usr/bin/tr -d ' ')
        while [ ! -f "$fixture/ready-$number" ]; do /bin/sleep 0.01; done
        printf '{"type":"ready","engineVersion":"fixture-engine-version"}\n'
        : > "$fixture/ready-sent-$number"
        while IFS= read -r request; do
            request_id=$(printf '%s\n' "$request" | /usr/bin/sed -E 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
            : > "$fixture/received-$number"
            while [ ! -f "$fixture/result-$number" ]; do /bin/sleep 0.01; done
            printf '{"type":"result","id":"%s","text":"reply-%s","duration":1,"elapsed":0.01,"language":"en"}\n' "$request_id" "$number"
            if [ -f "$fixture/send-error-$number" ]; then printf '{"type":"error","message":"stale process failure"}\n'; fi
            : > "$fixture/result-sent-$number"
        done
        """#
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        if ignoreTermination { try touch("ignore-termination") }
    }

    var startedProcesses: [pid_t] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("starts"), encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    func makeClient() -> TextCorrectionClient {
        TextCorrectionClient(modelURL: model, helperURL: helper)
    }

    func allowReady(_ number: Int) throws { try touch("ready-\(number)") }
    func allowResult(_ number: Int) throws { try touch("result-\(number)") }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func touch(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name)) }

    func cleanup() {
        // These PIDs were just launched by this fixture. Some tests intentionally
        // ignore SIGTERM to exercise stale replies, so always reclaim them here.
        for pid in startedProcesses where pid > 1 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: root)
    }
}
