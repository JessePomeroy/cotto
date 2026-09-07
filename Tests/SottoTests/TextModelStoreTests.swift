import CryptoKit
import Darwin
import Foundation
import SottoCore
import XCTest
@testable import Sotto

@MainActor
final class TextModelStoreTests: XCTestCase {
    func testMissingModelIsNotDownloadedOrCreatedByInspection() async throws {
        let fixture = try Fixture(createModels: false)
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        defer { store.shutdown() }
        store.inspect()
        let installed = await store.verifyInstalled()
        XCTAssertFalse(installed)
        XCTAssertEqual(store.snapshot.status, .missing)
        XCTAssertEqual(store.snapshot.bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.root.path),
                       "A read-only model check must not create a folder or begin a download")
    }

    func testCorruptModelFailsPinnedIntegrityCheckWithoutChangingItsBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeArtifact(to: fixture.paths.model)
        let corrupt = Data("not a real model".utf8)
        let weights = fixture.paths.model.appendingPathComponent("model.safetensors")
        try corrupt.write(to: weights)
        let store = fixture.makeStore()
        defer { store.shutdown() }
        let installed = await store.verifyInstalled()
        XCTAssertFalse(installed)
        XCTAssertEqual(store.snapshot.status, .failed)
        XCTAssertTrue(store.snapshot.error?.contains("incomplete") == true)
        XCTAssertEqual(try Data(contentsOf: weights), corrupt)
    }

    func testSymlinkedModelCannotBeInspectedOrRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("leave-this-folder")
        try fixture.writeArtifact(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.paths.model, withDestinationURL: target)
        let store = fixture.makeStore()
        defer { store.shutdown() }
        let installed = await store.verifyInstalled()
        XCTAssertFalse(installed)
        XCTAssertEqual(store.snapshot.status, .failed)
        if case .success = store.remove() { XCTFail("Removing a symbolic-link model path must fail") }
        try fixture.model.verify(target).get()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.paths.model.path), target.path)
    }

    func testSymlinkedModelsDirectoryFailsBeforeStartingADownload() throws {
        let fixture = try Fixture(createModels: false)
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.paths.root, withIntermediateDirectories: true)
        let target = fixture.root.appendingPathComponent("unrelated-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: fixture.paths.models, withDestinationURL: target)
        let store = fixture.makeStore()
        defer { store.shutdown() }
        store.download()
        XCTAssertEqual(store.snapshot.status, .failed)
        XCTAssertTrue(store.snapshot.error?.contains("private folder") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testRemovingWhileInspectionIsPendingDoesNotPublishAStaleFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeArtifact(to: fixture.paths.model)
        let store = fixture.makeStore()
        defer { store.shutdown() }
        store.inspect()
        XCTAssertEqual(store.snapshot.status, .verifying)
        try store.remove().get()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.snapshot.status, .missing)
        XCTAssertNil(store.snapshot.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.model.path))
        try fixture.writeArtifact(to: fixture.paths.model)
        let installed = await store.verifyInstalled()
        XCTAssertTrue(installed)
        XCTAssertEqual(store.snapshot.status, .installed, "A subsequent inspection must not reuse the obsolete task")
    }

    func testImportMakesVerifiedPrivateCopiesOfCachedSymlinksAndLeavesOldGGUF() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("snapshot")
        let blobs = fixture.root.appendingPathComponent("blobs")
        try fixture.writeArtifact(to: blobs)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        for file in fixture.model.files {
            try FileManager.default.createSymbolicLink(at: source.appendingPathComponent(file.filename),
                withDestinationURL: blobs.appendingPathComponent(file.filename))
        }
        let legacy = fixture.paths.models.appendingPathComponent("Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
        let legacyBytes = Data("leave the previous model alone".utf8)
        try legacyBytes.write(to: legacy)
        let store = fixture.makeStore()
        defer { store.shutdown() }
        try await store.importVerified(from: source).get()
        XCTAssertEqual(store.snapshot.status, .installed)
        XCTAssertEqual(store.snapshot.bytes, fixture.model.byteCount)
        try fixture.model.verify(fixture.paths.model).get()
        XCTAssertEqual(try Data(contentsOf: legacy), legacyBytes)
        for file in fixture.model.files {
            let target = fixture.paths.model.appendingPathComponent(file.filename)
            let info = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual(info[.type] as? FileAttributeType, .typeRegular)
            XCTAssertEqual((info[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let sourceInfo = try FileManager.default.attributesOfItem(atPath: blobs.appendingPathComponent(file.filename).path)
            XCTAssertNotEqual(info[.systemFileNumber] as? NSNumber, sourceInfo[.systemFileNumber] as? NSNumber)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.paths.model.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    func testInvalidImportDoesNotReplaceExistingModelAndSuccessfulReimportSwapsDirectories() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeArtifact(to: fixture.paths.model)
        let source = fixture.root.appendingPathComponent("source")
        try fixture.writeArtifact(to: source)
        let corruptFile = source.appendingPathComponent("tokenizer.json")
        let original = try Data(contentsOf: corruptFile)
        try Data(repeating: 0, count: original.count).write(to: corruptFile)
        let store = fixture.makeStore()
        defer { store.shutdown() }
        if case .success = await store.importVerified(from: source) { XCTFail("A mismatched digest must fail import") }
        try fixture.model.verify(fixture.paths.model).get()
        try original.write(to: corruptFile)
        try await store.importVerified(from: source).get()
        try fixture.model.verify(fixture.paths.model).get()
        XCTAssertEqual(store.snapshot.status, .installed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.models.path), [fixture.model.filename])
    }

    func testMissingOrUnexpectedFilesAndNestedSymlinksFailVerification() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeArtifact(to: fixture.paths.model)
        let file = fixture.paths.model.appendingPathComponent("tokenizer.json")
        try FileManager.default.removeItem(at: file)
        if case .success = fixture.model.verify(fixture.paths.model) { XCTFail("Every pinned file is required") }
        let target = fixture.root.appendingPathComponent("external-tokenizer")
        try fixture.payloads["tokenizer.json"]!.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        if case .success = fixture.model.verify(fixture.paths.model) { XCTFail("Installed model files must not be symlinks") }
        try FileManager.default.removeItem(at: file)
        try fixture.payloads["tokenizer.json"]!.write(to: file)
        try Data("unexpected weights".utf8).write(to: fixture.paths.model.appendingPathComponent("extra.safetensors"))
        if case .success = fixture.model.verify(fixture.paths.model) { XCTFail("Unpinned weights must not be loaded") }
    }

    func testCancelledImportCannotInstallOrOverwriteTheNextImportState() async throws {
        let fixture = try Fixture(weightBytes: 16 * 1024 * 1024)
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        try fixture.writeArtifact(to: source)
        let store = fixture.makeStore()
        defer { store.shutdown() }
        let pending = Task { await store.importVerified(from: source) }
        while store.snapshot.status == .missing { await Task.yield() }
        XCTAssertEqual(store.snapshot.status, .verifying)
        store.cancelDownload()
        let cancelled = await pending.value
        if case .success = cancelled { XCTFail("The cancelled import must not install") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.model.path))
        try await store.importVerified(from: source).get()
        XCTAssertEqual(store.snapshot.status, .installed)
        try fixture.model.verify(fixture.paths.model).get()
    }

    func testDownloadFetchesAndVerifiesEveryPinnedFileBeforeInstalling() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        ModelURLProtocol.reset(payloads: fixture.payloads)
        defer { ModelURLProtocol.reset(payloads: [:]) }
        let store = fixture.makeStore(protocolClass: ModelURLProtocol.self)
        defer { store.shutdown() }
        store.download()
        let deadline = ContinuousClock.now + .seconds(5)
        while store.snapshot.status == .downloading || store.snapshot.status == .verifying {
            guard ContinuousClock.now < deadline else { return XCTFail("The stub download did not finish") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.snapshot.status, .installed, store.snapshot.error ?? "")
        XCTAssertEqual(Set(ModelURLProtocol.requestedNames), Set(fixture.model.files.map(\.filename)))
        XCTAssertEqual(store.snapshot.bytes, fixture.model.byteCount)
        try fixture.model.verify(fixture.paths.model).get()
    }

    func testAggregateIdentityIsStableButIncludesTokenizerAndConfiguration() {
        let model = TextModel.qwen
        let reordered = TextModel(id: model.id, name: model.name, filename: model.filename, files: Array(model.files.reversed()))
        XCTAssertEqual(model.sha256, reordered.sha256)
        XCTAssertEqual(model.sha256, "6689706a7d1a746920df5c5d5dc1e8ed3280790a542085d6e3c870c565e77307")
        let weightsOnly = TextModel(id: model.id, name: model.name, filename: model.filename,
                                   files: model.files.filter { $0.filename == "model.safetensors" })
        XCTAssertNotEqual(model.sha256, weightsOnly.sha256)
    }

    @MainActor private struct Fixture {
        let root: URL
        let paths: TextModelPaths
        let model: TextModel
        let payloads: [String: Data]

        init(createModels: Bool = true, weightBytes: Int? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Sotto-text-model-test-\(UUID().uuidString)")
            paths = TextModelPaths(root: root.appendingPathComponent("sotto"))
            var data = Dictionary(uniqueKeysWithValues: TextModel.qwen.files.map { ($0.filename, Data("fixture-\($0.filename)".utf8)) })
            if let weightBytes { data["model.safetensors"] = Data(repeating: 42, count: weightBytes) }
            payloads = data
            model = TextModel(id: "fixture", name: "Fixture", filename: TextModel.qwen.filename,
                files: TextModel.qwen.files.map {
                    let payload = data[$0.filename]!
                    return TextModel.File(filename: $0.filename, byteCount: Int64(payload.count),
                        sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                        downloadURL: URL(string: "https://sotto-model-test.invalid/\($0.filename)")!)
                })
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if createModels { try FileManager.default.createDirectory(at: paths.models, withIntermediateDirectories: true) }
        }

        func makeStore(protocolClass: AnyClass? = nil) -> TextModelStore {
            TextModelStore(paths: paths, model: model, sessionConfiguration: {
                let config = URLSessionConfiguration.ephemeral
                if let protocolClass { config.protocolClasses = [protocolClass] }
                return config
            })
        }

        func writeArtifact(to directory: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, payload) in payloads { try payload.write(to: directory.appendingPathComponent(name)) }
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class ModelURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var payloads: [String: Data] = [:]
    private static var requests: [String] = []

    static var requestedNames: [String] { lock.withLock { requests } }
    static func reset(payloads: [String: Data]) { lock.withLock { self.payloads = payloads; requests = [] } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sotto-model-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let data = Self.lock.withLock {
            Self.requests.append(url.lastPathComponent)
            return Self.payloads[url.lastPathComponent]
        }
        guard let data else { client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
