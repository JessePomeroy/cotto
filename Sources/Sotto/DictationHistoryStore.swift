import AppKit
import Combine
import SottoCore

/// Owns finished capture files until their background archive write completes.
/// This is separate from transcription/delivery so disk latency never delays paste.
@MainActor
final class DictationHistoryStore: ObservableObject {
    /// Used only when migrating pre-config.json preferences.
    static let enabledKey = "saveDictationHistory"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue, !applyingConfiguration else { return }
            configuration.update { $0.saveDictationHistory = isEnabled }
        }
    }
    @Published private(set) var pendingSaveCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastSavedAt: Date?
    let directory: URL

    private let configuration: ConfigurationStore
    private let writer: DictationArchiveWriter
    private var subscriptions: Set<AnyCancellable> = []
    private var applyingConfiguration = false
    private var saves: [UUID: Task<Void, Never>] = [:]

    init(configuration: ConfigurationStore, writer: DictationArchiveWriter = DictationArchiveWriter()) {
        self.configuration = configuration
        self.writer = writer
        directory = writer.transcriptsDirectory
        isEnabled = configuration.configuration.saveDictationHistory
        configuration.$configuration
            .map(\.saveDictationHistory)
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, isEnabled != enabled else { return }
                applyingConfiguration = true
                isEnabled = enabled
                applyingConfiguration = false
            }
            .store(in: &subscriptions)
    }

    /// The caller has already snapshotted the retention preference for this take.
    /// Later preference changes must not discard a completed, queued recording.
    func enqueue(record: DictationArchiveRecord, originalAudio: URL, transcriptionAudio: URL,
                 cleanup: @escaping @Sendable () -> Void) {
        let jobID = UUID()
        pendingSaveCount += 1
        saves[jobID] = Task {
            let result = await writer.save(record: record, originalAudio: originalAudio,
                                           transcriptionAudio: transcriptionAudio)
            // File removal, like copies, stays off the UI actor.
            await Task.detached(priority: .utility) { cleanup() }.value
            switch result {
            case .success:
                lastSavedAt = Date()
                // A later successful take must not hide an earlier lost save.
            case .failure(let error):
                lastError = error.localizedDescription
                    + " This take was not archived; its temporary audio was discarded."
            }
            saves[jobID] = nil
            pendingSaveCount -= 1
        }
    }

    func reportMissingOriginal() {
        lastError = "This take was not archived because its original audio was unavailable."
    }

    /// Normal app termination waits for already-finalized takes, not unfinished dictation.
    func flush() async {
        while let save = saves.values.first { await save.value }
    }

    func openFolder() {
        Task {
            switch await writer.prepare() {
            case .success(let folder):
                if !NSWorkspace.shared.open(folder) {
                    lastError = "Finder could not open the history folder at \(folder.path)."
                }
            case .failure(let error):
                lastError = error.localizedDescription
            }
        }
    }

    func dismissError() { lastError = nil }
}

/// Immutable settings captured at key-down. No destination document text is retained.
struct DictationHistoryContext: Sendable {
    let id: UUID
    let startedAt: Date
    let mode: DictationArchiveRecord.Mode
    let microphone: DictationArchiveRecord.Microphone
    let language: String
    let prompt: String
    let removeFillers: Bool

    func record(audio: CapturedAudio, original: OriginalCapturedAudio,
                releasedAt: Date, completedAt: Date, outcome: DictationArchiveRecord.Outcome,
                result: TranscriptionResult?, transcript: String, transcriptionWallSeconds: Double?,
                releaseToResultSeconds: Double, deliveryStatus: DictationDeliveryStatus?,
                errorMessage: String?, engineVersion: String? = nil,
                textProcessing: TextProcessingRecord? = nil) -> DictationArchiveRecord {
        let model = SpeechModel.turbo
        return DictationArchiveRecord(
            id: id, startedAt: startedAt, releasedAt: releasedAt, completedAt: completedAt,
            mode: mode, outcome: outcome, rawText: result?.text ?? "", transcriptText: transcript,
            model: .init(id: model.id, name: model.name, sha256: model.sha256,
                         engine: "whisper.cpp", engineVersion: engineVersion ?? "unknown"),
            options: .init(requestedLanguage: language, detectedLanguage: result?.language,
                           removeFillers: removeFillers, vocabularyPrompt: prompt),
            microphone: microphone,
            audio: .init(
                original: .init(sampleRate: original.sampleRate, channels: Int(original.channelCount),
                                sampleFormat: original.encoding, frameCount: original.frameCount,
                                durationSeconds: Double(original.frameCount) / original.sampleRate),
                transcription: .init(sampleRate: 16_000, channels: 1, sampleFormat: "pcm_f32le",
                                     frameCount: Int64((audio.duration * 16_000).rounded()),
                                     durationSeconds: audio.duration)),
            timing: .init(engineProcessingSeconds: result?.processingSeconds,
                          transcriptionWallSeconds: transcriptionWallSeconds,
                          releaseToResultSeconds: releaseToResultSeconds),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            deliveryStatus: deliveryStatus?.rawValue, errorMessage: errorMessage, textProcessing: textProcessing
        )
    }
}
