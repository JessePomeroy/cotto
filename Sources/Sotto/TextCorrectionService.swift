import Combine
import Foundation
import SottoCore

/// Owns the optional second model. It never downloads implicitly or blocks the
/// recording path; correction failures return the deterministic transcript.
@MainActor
final class TextCorrectionService: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            guard !applyingConfiguration, enabled != oldValue else { return }
            configuration.update { $0.textCorrectionEnabled = enabled }
            if !enabled, !isBusy { unload() }
        }
    }
    @Published private(set) var modelStatus: ModelStatus = .missing
    @Published private(set) var engineStatus: EngineStatus = .unloaded
    @Published private(set) var progress: Double = 0
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var message = "Download the text model to enable local corrections."
    @Published private(set) var lastOutcome: String?

    var modelName: String { TextModel.qwen.name }
    var modelSizeLabel: String { ByteCountFormatter.string(fromByteCount: TextModel.qwen.byteCount, countStyle: .file) }

    private let configuration: ConfigurationStore
    private let client: TextCorrectionClient
    private let modelStore: TextModelStore
    private var subscriptions = Set<AnyCancellable>()
    private var applyingConfiguration = false
    private var isBusy = false
    private var isShuttingDown = false
    private var warmTask: Task<Void, Never>?
    private var warmID: UUID?
    private var idleTask: Task<Void, Never>?

    init(configuration: ConfigurationStore, client: TextCorrectionClient? = nil,
         modelStore: TextModelStore? = nil, inspectOnInit: Bool = true) {
        let client = client ?? TextCorrectionClient()
        let modelStore = modelStore ?? TextModelStore()
        self.configuration = configuration
        self.client = client
        self.modelStore = modelStore
        enabled = configuration.configuration.textCorrectionEnabled
        modelStore.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            self.modelStatus = snapshot.status
            self.progress = snapshot.progress
            self.downloadedBytes = snapshot.bytes
            if let error = snapshot.error { self.message = error }
            else if snapshot.status == .installed { self.message = "Ready for local text correction." }
            else if snapshot.status == .verifying { self.message = "Checking the model…" }
            else if snapshot.status == .downloading { self.message = "Downloading the text model…" }
            else if snapshot.status == .missing { self.message = "Download the text model to enable local corrections." }
        }.store(in: &subscriptions)
        client.$status.sink { [weak self] status in
            guard let self else { return }
            self.engineStatus = status
            switch status {
            case .loading: self.message = "Loading the local text model…"
            case .transcribing: self.message = "Proofreading on this Mac…"
            case .ready: self.message = "Loaded in memory."
            case .unloaded where self.modelStatus == .installed:
                self.message = self.enabled ? "Loads automatically when you dictate." : "Text correction is off. Your dictionary stays active."
            default: break
            }
        }.store(in: &subscriptions)
        configuration.$configuration.sink { [weak self] settings in
            guard let self else { return }
            self.applyingConfiguration = true
            self.enabled = settings.textCorrectionEnabled
            self.applyingConfiguration = false
            if !self.isBusy {
                if !self.enabled { self.unload() }
                else {
                    if self.engineStatus == .unloaded, self.modelStatus == .installed {
                        self.message = "Loads automatically when you dictate."
                    }
                    self.scheduleUnload(idleMinutes: settings.idleMinutes)
                }
            }
        }.store(in: &subscriptions)
        if inspectOnInit { modelStore.inspect() }
    }

    func download() { guard !isBusy else { return }; modelStore.download() }
    func cancelDownload() { modelStore.cancelDownload() }

    func load() {
        guard !isBusy, !isShuttingDown, modelStatus == .installed else { return }
        startWarmup()
    }

    func unload() {
        idleTask?.cancel()
        idleTask = nil
        warmTask?.cancel()
        warmTask = nil
        warmID = nil
        client.unload()
    }

    func remove() {
        guard !isBusy else { return }
        unload()
        if case .failure(let error) = modelStore.remove() { message = error.localizedDescription }
    }

    func beginTake() {
        isBusy = true
        lastOutcome = nil
        idleTask?.cancel()
        idleTask = nil
        if enabled, modelStatus == .installed { startWarmup() }
    }

    func endTake() {
        isBusy = false
        if !enabled { unload() }
        else { scheduleUnload(idleMinutes: configuration.configuration.idleMinutes) }
    }

    func cancelTake() {
        warmTask?.cancel()
        warmTask = nil
        warmID = nil
        client.cancelCurrentOperation()
        endTake()
    }

    func shutdown() {
        isShuttingDown = true
        subscriptions.removeAll()
        unload()
        modelStore.shutdown()
    }

    func process(_ text: String, dictionary: PersonalDictionary, dictionaryChangedText: Bool,
                 language: String, enabledForTake: Bool) async throws -> TextProcessingRecord {
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        let terms = dictionary.vocabularyTerms
        func record(_ status: TextProcessingRecord.Status, output: String? = nil,
                    reason: String? = nil, seconds: Double? = nil) -> TextProcessingRecord {
            TextProcessingRecord(dictionaryTerms: terms, dictionaryChangedText: dictionaryChangedText,
                                 inputText: text, outputText: output ?? text, enabled: enabledForTake,
                                 status: status, reason: reason,
                                 modelID: enabledForTake ? TextModel.qwen.id : nil,
                                 modelSHA256: enabledForTake ? TextModel.qwen.sha256 : nil,
                                 engineVersion: client.engineVersion, processingSeconds: seconds,
                                 wallSeconds: ProcessInfo.processInfo.systemUptime - started)
        }
        guard enabledForTake else { lastOutcome = "Dictionary only"; return record(.disabled) }
        guard !text.isEmpty else { return record(.skipped, reason: "No text to correct.") }
        guard text.count <= TextCorrectionPolicy.maximumInputCharacters else {
            lastOutcome = "Long transcript kept without a model rewrite"
            return record(.skipped, reason: "The transcript exceeded the correction length limit.")
        }
        guard modelStatus == .installed else {
            lastOutcome = "Dictionary only · text model unavailable"
            return record(.unavailable, reason: "The text model is not installed or verified.")
        }
        do {
            let result = try await client.correct(text, terms: TextCorrectionPolicy.modelHints(terms), language: language)
            try Task.checkCancellation()
            let candidate = dictionary.apply(to: result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            let reason = await Task.detached(priority: .userInitiated) {
                TextCorrectionPolicy.rejectionReason(original: text, candidate: candidate, preferredTerms: terms)
            }.value
            try Task.checkCancellation()
            if let reason {
                lastOutcome = "Original kept · rewrite did not pass checks"
                return record(.rejected, reason: reason, seconds: result.processingSeconds)
            }
            lastOutcome = candidate == text ? "Checked · no changes needed" : "Corrected locally"
            return record(candidate == text ? .unchanged : .applied, output: candidate, seconds: result.processingSeconds)
        } catch {
            try Task.checkCancellation()
            lastOutcome = "Dictionary only · text correction failed"
            message = "Text correction was skipped: \(error.localizedDescription)"
            return record(.failed, reason: error.localizedDescription)
        }
    }

    private func startWarmup() {
        guard warmTask == nil, client.status != .ready else { return }
        let current = UUID()
        warmID = current
        warmTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.warmID == current { self.warmTask = nil; self.warmID = nil }
            }
            do {
                try await self.client.ensureLoaded()
                guard !Task.isCancelled, self.warmID == current else { return }
                self.message = "Loaded in memory."
                if !self.isBusy { self.scheduleUnload(idleMinutes: self.configuration.configuration.idleMinutes) }
            } catch {
                if !Task.isCancelled, self.warmID == current {
                    self.message = "Text model could not load: \(error.localizedDescription)"
                }
            }
        }
    }

    private func scheduleUnload(idleMinutes: Int) {
        idleTask?.cancel()
        idleTask = nil
        guard !isBusy, !isShuttingDown, client.status == .ready,
              let delay = LifecyclePolicy.unloadDelay(idleMinutes: idleMinutes) else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, !Task.isCancelled, !self.isBusy, !self.isShuttingDown else { return }
            self.client.unload(reason: "Resting after inactivity")
            self.idleTask = nil
        }
    }
}
