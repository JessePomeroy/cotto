import AppKit
import Combine
import SottoCore
import ServiceManagement

private enum DictationDestination: Equatable {
    case test
    case field(InsertionTarget)
}

@MainActor
final class SottoController: ObservableObject {
    @Published var activity: DictationActivity = .idle {
        didSet {
            if oldValue.isBusy, !activity.isBusy {
                textCorrection.endTake()
                applyConfiguration(configuration.configuration)
            }
        }
    }
    let recordingFeedback = RecordingFeedback()
    @Published var recordingListHint: String?
    @Published private(set) var recordingInputName: String?
    @Published var lastTranscript = ""
    @Published var lastTranscriptionSeconds: Double?
    @Published var lastAudioSeconds: Double?
    @Published var lastDelivery = ""
    @Published private(set) var lastDeliveryStatus: DictationDeliveryStatus = .none
    @Published var errorMessage: String?
    @Published var permissions: PermissionSnapshot
    @Published var isHotkeyActive = false
    @Published private(set) var isCheckingShortcut = false
    @Published private(set) var shortcutCheckText = ""
    @Published var shortcut: HoldKey = .rightOption {
        didSet {
            if shortcut != oldValue { stopShortcutCheck() }
            if !applyingConfiguration { configuration.update { $0.holdKey = shortcut.rawValue } }
            hotkey.key = shortcut
        }
    }
    @Published var language = "en" {
        didSet { if !applyingConfiguration { configuration.update { $0.language = language } } }
    }
    @Published var idleMinutes = 5 {
        didSet {
            if !applyingConfiguration { configuration.update { $0.idleMinutes = idleMinutes } }
            scheduleUnload()
        }
    }
    @Published var cleanText = true {
        didSet { if !applyingConfiguration { configuration.update { $0.cleanText = cleanText } } }
    }
    @Published var vocabulary = "" {
        didSet { if !applyingConfiguration { configuration.update { $0.vocabulary = vocabulary } } }
    }
    @Published var launchAtLogin = false {
        didSet {
            guard hasInitialized, !applyingConfiguration, !updatingLogin, launchAtLogin != oldValue else { return }
            configuration.update { $0.launchAtLogin = launchAtLogin }
            updateLoginItem()
        }
    }
    @Published private(set) var loginItemError: String?
    @Published var modelStatus: ModelStatus = .missing
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var modelError: String?
    @Published var engineStatus: EngineStatus = .unloaded
    @Published var engineMessage = "Loads when you need it"
    @Published var statusMessage = "Ready when you are"
    let configuration: ConfigurationStore
    let microphones: MicrophonePreferencesStore
    let history: DictationHistoryStore
    let textCorrection: TextCorrectionService

    var isRecording: Bool { activity == .recording }
    var isCapturing: Bool { activity.isCapturing }
    var recordingUsesClipboard: Bool { isCapturing && insertionDestination == .clipboard }
    var isBusy: Bool { activity.isBusy }
    // Escape belongs to the foreground app while Fn is held for navigation.
    // The HUD's explicit cancel button remains available throughout the take.
    var canCancelWithEscape: Bool { !hotkey.isHoldingFn }
    var isModelInstalled: Bool { modelStatus == .installed }
    var canTest: Bool { isModelInstalled && permissions.microphone && microphones.resolution.device != nil && !isBusy }
    var selectedInputName: String { microphones.resolution.device?.name ?? "No microphone available" }
    var allPermissionsGranted: Bool { permissions.microphone && permissions.accessibility }
    var modelSizeLabel: String { "1.62 GB" }
    var engineStatusLabel: String {
        switch engineStatus {
        case .unloaded: "Idle"
        case .loading: "Loading model"
        case .ready: "Ready"
        case .transcribing: "Transcribing"
        case .failed: "Needs attention"
        }
    }

    var onHUDVisibility: ((Bool) -> Void)?
    var onShowWindow: (() -> Void)?
    private let recorder = AudioRecorder()
    private let audioDevices = AudioDeviceStore()
    private var microphoneSubscription: AnyCancellable?
    private var configurationSubscription: AnyCancellable?
    private var applyingConfiguration = false
    private let hotkey = HotkeyMonitor()
    private let inserter = TextInserter()
    private let modelStore: ModelStore
    private let engine = EngineClient()
    private var recordingTimer: Timer?
    private var recordingStart: TimeInterval = 0
    private var recordingHistory: DictationHistoryContext?
    private var recordingDictionary = PersonalDictionary.default
    private var recordingTextCorrectionEnabled = true
    private var microphoneStartTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var shortcutCheckTask: Task<Void, Never>?
    private var shortcutCheckStarted: TimeInterval = 0
    private var shortcutCheckEntries: [String] = []
    private var sessionID = UUID()
    @Published private var insertionDestination: InsertionDestination?
    private var destinationTask: Task<InsertionDestination, Never>?
    private var recordingClipboardChangeCount = 0
    private var continuationMemory = DictationContinuationMemory<DictationDestination>()
    private var activeContinuation: DictationContinuation?
    private var isTestSession = false
    private var updatingLogin = false
    private var hasInitialized = false
    private var isShuttingDown = false
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?

    /// Disabling services permits offscreen native view previews with an isolated config.
    /// It does not inspect models, register input listeners, or clean capture/download files.
    init(configuration: ConfigurationStore, startServices: Bool = true) {
        self.configuration = configuration
        permissions = startServices ? PermissionSnapshot.capture()
            : PermissionSnapshot(microphone: false, accessibility: false, inputMonitoring: false)
        modelStore = ModelStore(paths: startServices ? SottoPaths()
            : SottoPaths(root: configuration.url.deletingLastPathComponent().appendingPathComponent("preview-models")))
        microphones = MicrophonePreferencesStore(configuration: configuration)
        history = DictationHistoryStore(configuration: configuration, writer: DictationArchiveWriter(
            root: startServices ? nil : configuration.url.deletingLastPathComponent().appendingPathComponent("preview-history")))
        textCorrection = TextCorrectionService(configuration: configuration, inspectOnInit: startServices)
        applyConfiguration(configuration.configuration)
        hotkey.key = shortcut
        guard startServices else { return }
        bindServices()
        audioDevices.start()
        installLifecycleObservers()
        modelStore.inspect()
        refreshPermissions()
        CapturedAudio.cleanupOrphans()
        hasInitialized = true
        configurationSubscription = configuration.$configuration.removeDuplicates()
            .sink { [weak self] in self?.applyConfiguration($0) }
        updateLoginItem()
    }

    private func applyConfiguration(_ settings: SottoConfiguration) {
        // A changed hold key must not reset/cancel a live recording, and every
        // take keeps the transcription settings it started with.
        guard !isBusy, !isShuttingDown else { return }
        applyingConfiguration = true
        let loginChanged = launchAtLogin != settings.launchAtLogin
        if let key = HoldKey(rawValue: settings.holdKey), shortcut != key { shortcut = key }
        if language != settings.language { language = settings.language }
        if idleMinutes != settings.idleMinutes { idleMinutes = settings.idleMinutes }
        if cleanText != settings.cleanText { cleanText = settings.cleanText }
        if vocabulary != settings.vocabulary { vocabulary = settings.vocabulary }
        if loginChanged { launchAtLogin = settings.launchAtLogin }
        applyingConfiguration = false
        if hasInitialized, loginChanged { updateLoginItem() }
    }

    func refreshPermissions() {
        let current = PermissionSnapshot.capture()
        if current != permissions { permissions = current }
        audioDevices.refresh()
        if permissions.canListenForHotkey {
            isHotkeyActive = hotkey.start()
        } else {
            hotkey.stop()
            isHotkeyActive = false
        }
    }

    func requestMicrophone() {
        if permissions.microphone {
            PermissionManager.openMicrophoneSettings()
            return
        }
        Task {
            _ = await PermissionManager.requestMicrophone()
            refreshPermissions()
        }
    }

    func requestAccessibility() {
        if permissions.accessibility { PermissionManager.openAccessibilitySettings() }
        else { PermissionManager.requestAccessibility() }
        retryPermissions()
    }

    func requestInputMonitoring() {
        if permissions.inputMonitoring { PermissionManager.openInputMonitoringSettings() }
        else { PermissionManager.requestInputMonitoring() }
        retryPermissions()
    }

    func startShortcutCheck() {
        guard !isBusy, !isCheckingShortcut else { return }
        refreshPermissions()
        shortcutCheckStarted = ProcessInfo.processInfo.systemUptime
        shortcutCheckEntries = []
        isCheckingShortcut = true
        hotkey.onDiagnostic = { [weak self] message in self?.appendShortcutCheck(message) }
        hotkey.requireFreshHold()
        appendShortcutCheck("Checking \(shortcut.title) for 60 seconds. The microphone stays off.")
        appendShortcutCheck("Listener: \(isHotkeyActive ? "enabled" : "unavailable"); Accessibility: \(permissions.accessibility); Input Monitoring: \(permissions.inputMonitoring).")
        shortcutCheckTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.stopShortcutCheck()
        }
    }

    func stopShortcutCheck() {
        guard isCheckingShortcut else { return }
        // Reset before leaving check mode: a delayed callback must never start
        // the microphone just because this check timed out during a held key.
        hotkey.requireFreshHold()
        appendShortcutCheck("Check ended. No audio was recorded.")
        hotkey.onDiagnostic = nil
        isCheckingShortcut = false
        shortcutCheckTask?.cancel()
        shortcutCheckTask = nil
    }

    private func appendShortcutCheck(_ message: String) {
        guard isCheckingShortcut else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - shortcutCheckStarted
        let context = NSApp.isActive ? "Sotto" : "background"
        shortcutCheckEntries.append(String(format: "%.2fs", elapsed) + " [\(context)] " + message)
        shortcutCheckEntries = Array(shortcutCheckEntries.suffix(16))
        shortcutCheckText = shortcutCheckEntries.joined(separator: "\n")
    }

    func downloadModel() {
        guard !isBusy else { return }
        errorMessage = nil
        modelStore.download()
    }

    func cancelDownload() { modelStore.cancelDownload() }

    func warmModel() {
        guard isModelInstalled, !isBusy, engineStatus != .loading else { return }
        idleTask?.cancel()
        errorMessage = nil
        warmTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.ensureLoaded()
                if !Task.isCancelled { scheduleUnload() }
            } catch is CancellationError {
            } catch EngineError.cancelled {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func unloadModel() {
        guard !isBusy else { return }
        idleTask?.cancel()
        warmTask?.cancel()
        engine.unload()
    }

    func revealModel() {
        if isModelInstalled {
            NSWorkspace.shared.activateFileViewerSelecting([modelStore.paths.model])
        } else {
            try? FileManager.default.createDirectory(at: modelStore.paths.models, withIntermediateDirectories: true)
            NSWorkspace.shared.open(modelStore.paths.models)
        }
    }

    func removeModel() {
        guard !isBusy else { return }
        unloadModel()
        if case .failure(let error) = modelStore.remove() { errorMessage = error.localizedDescription }
    }

    func toggleTestRecording() {
        guard !hotkey.isHoldingFn else { return }
        if isCapturing { finishDictation() }
        else if !isBusy { beginDictation(isTest: true) }
    }

    func cancelDictation() {
        guard isBusy else { return }
        sessionID = UUID()
        microphoneStartTask?.cancel()
        microphoneStartTask = nil
        transcriptionTask?.cancel()
        warmTask?.cancel()
        destinationTask?.cancel()
        destinationTask = nil
        stopRecordingTimer()
        recorder.cancel()
        engine.cancelPendingWork()
        textCorrection.cancelTake()
        insertionDestination = nil
        activeContinuation = nil
        recordingListHint = nil
        recordingInputName = nil
        resetLevels()
        activity = .idle
        statusMessage = "Cancelled"
        errorMessage = nil
        hudTask?.cancel()
        onHUDVisibility?(false)
        scheduleUnload()
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty, !isBusy else { return }
        switch DictationClipboard.copy(lastTranscript, to: .general) {
        case .success:
            lastDelivery = "Copied to clipboard"
            lastDeliveryStatus = .copied
        case .failure(let error):
            lastDelivery = error.localizedDescription
            lastDeliveryStatus = .failed
        }
    }

    func clearLastTranscript() {
        guard !isBusy else { return }
        continuationMemory.removeAll()
        lastTranscript = ""
        lastTranscriptionSeconds = nil
        lastAudioSeconds = nil
        lastDelivery = ""
        lastDeliveryStatus = .none
        errorMessage = nil
        activity = .idle
    }

    func dismissFeedback() {
        guard !isBusy else { return }
        hudTask?.cancel()
        onHUDVisibility?(false)
        if activity == .success { activity = .idle }
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        configurationSubscription = nil
        configuration.stopWatching()
        stopShortcutCheck()
        cancelDictation()
        audioDevices.stop()
        microphoneSubscription = nil
        continuationMemory.removeAll()
        hotkey.stop()
        idleTask?.cancel()
        warmTask?.cancel()
        hudTask?.cancel()
        permissionTask?.cancel()
        microphoneStartTask?.cancel()
        microphoneStartTask = nil
        recorder.cancel()
        engine.unload()
        modelStore.shutdown()
        textCorrection.shutdown()
        memoryPressure?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
    }

    private func bindServices() {
        audioDevices.onChange = { [weak self] devices, systemDefaultUID in
            self?.microphones.update(devices: devices, systemDefaultUID: systemDefaultUID)
        }
        microphoneSubscription = microphones.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        modelStore.onChange = { [weak self] snapshot in
            guard let self else { return }
            if modelStatus != snapshot.status { modelStatus = snapshot.status }
            if downloadProgress != snapshot.progress { downloadProgress = snapshot.progress }
            if downloadedBytes != snapshot.bytes { downloadedBytes = snapshot.bytes }
            if modelError != snapshot.error { modelError = snapshot.error }
        }
        engine.onStatus = { [weak self] status, message in
            guard let self else { return }
            if self.engineStatus != status { self.engineStatus = status }
            if self.engineMessage != message { self.engineMessage = message }
            if status == .ready { self.scheduleUnload() }
        }
        recorder.onLevel = { [weak self] level in
            guard let self, self.isCapturing else { return }
            // Append every sample, including repeated zeroes, so old peaks
            // visibly leave the meter when the microphone becomes quiet.
            self.recordingFeedback.append(level)
        }
        recorder.onInterruption = { [weak self] message in
            guard let self else { return }
            cancelDictation()
            showError(message)
        }
        hotkey.onStatusChange = { [weak self] active in
            if self?.isHotkeyActive != active { self?.isHotkeyActive = active }
        }
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            if isCheckingShortcut { appendShortcutCheck("Shortcut recognized. Recording was intentionally skipped.") }
            else { beginDictation(isTest: false) }
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            if isCheckingShortcut { appendShortcutCheck("Hold released."); return }
            guard !isTestSession else { return }
            finishDictation()
        }
        hotkey.onCancel = { [weak self] in
            guard let self else { return }
            if isCheckingShortcut { appendShortcutCheck("Hold cancelled; microphone stayed off.") }
            else if isBusy { cancelDictation() }
            else { dismissFeedback() }
        }
    }

    private func beginDictation(isTest: Bool) {
        guard !isBusy, !isShuttingDown else { return }
        stopShortcutCheck()
        // Inventory listeners and permission refreshes keep these snapshots
        // current. Do not rescan every audio device or rebuild a tap on key-down.
        // The recorder verifies the chosen device and microphone permission again.
        guard isModelInstalled else {
            showError(modelStatus == .verifying ? "The model is being verified. Try again in a moment." : "Download the speech model to get started.")
            onShowWindow?()
            return
        }
        guard permissions.microphone else {
            showError("Allow microphone access, then try again.")
            onShowWindow?()
            return
        }
        guard let input = microphones.resolution.device, let deviceID = audioDevices.deviceID(for: input.uid) else {
            showError("No microphone is available. Connect an audio input and try again.")
            onShowWindow?()
            return
        }
        idleTask?.cancel()
        hudTask?.cancel()
        errorMessage = nil
        sessionID = UUID()
        let current = sessionID
        isTestSession = isTest
        recordingDictionary = configuration.configuration.dictionary
        recordingTextCorrectionEnabled = configuration.configuration.textCorrectionEnabled
        let prompt = TranscriptCleaner.vocabularyPrompt(
            (recordingDictionary.vocabularyTerms + [vocabulary]).joined(separator: ", "))
        let saveHistory = history.isEnabled
        recordingHistory = saveHistory ? DictationHistoryContext(
            id: current, startedAt: Date(), mode: isTest ? .test : .hotkey,
            microphone: .init(uid: input.uid, name: input.name), language: language,
            prompt: prompt, removeFillers: cleanText
        ) : nil
        recordingClipboardChangeCount = NSPasteboard.general.changeCount
        insertionDestination = nil
        destinationTask?.cancel()
        destinationTask = nil
        recordingInputName = input.name
        recordingStart = ProcessInfo.processInfo.systemUptime
        recordingFeedback.reset()
        activity = .starting
        statusMessage = "Starting microphone…"
        onHUDVisibility?(true)
        startRecordingTimer()
        prepareContinuation(for: isTest ? .test : nil)
        if !isTest {
            // AX queries into another app can be slow. Do not delay microphone
            // startup, the HUD, or global key delivery on their IPC responses.
            let capture = TextInserter.beginDestinationCapture()
            destinationTask = capture
            Task { [weak self] in
                let destination = await capture.value
                guard let self, self.sessionID == current, self.isCapturing else { return }
                self.insertionDestination = destination
                let anchor = destination.target.flatMap { $0.selection == nil ? nil : DictationDestination.field($0) }
                self.prepareContinuation(for: anchor)
            }
        }
        microphoneStartTask = Task { [weak self] in
            guard let self, current == sessionID, activity == .starting, !Task.isCancelled else { return }
            defer { if current == sessionID { microphoneStartTask = nil } }
            do {
                // Resolve once per take. Reordering preferences or connecting a
                // higher-priority input never reroutes an in-flight recording.
                try await recorder.start(deviceID: deviceID, preserveOriginalAudio: saveHistory)
                guard current == sessionID, activity == .starting, !Task.isCancelled else { return }
                activity = .recording
                statusMessage = "Listening"
            } catch is CancellationError {
                if activity == .starting { settleCancelledSession(current) }
            } catch AudioRecordingError.cancelled {
                if activity == .starting { settleCancelledSession(current) }
            } catch {
                guard current == sessionID, activity == .starting, !Task.isCancelled else { return }
                cancelDictation()
                showError(error.localizedDescription)
                refreshPermissions()
            }
        }
        textCorrection.beginTake()
        warmTask = Task { [weak self] in
            guard let self, current == sessionID, isCapturing, !Task.isCancelled else { return }
            do {
                try await engine.ensureLoaded()
            } catch is CancellationError {
                settleCancelledSession(current)
            } catch EngineError.cancelled {
                settleCancelledSession(current)
            } catch {
                guard current == sessionID, isCapturing, !Task.isCancelled else { return }
                cancelDictation()
                showError(error.localizedDescription)
            }
        }
    }

    private func finishDictation() {
        guard isCapturing else { return }
        let releasedAt = ProcessInfo.processInfo.systemUptime
        let releaseDate = Date()
        recorder.stopAcceptingAudio()
        // A modifier tap/chord is not a failed dictation. It can still give
        // immediate visual feedback without leaving a red error behind.
        guard releasedAt - recordingStart >= 0.25 else {
            cancelDictation()
            return
        }
        let releasedDuringStartup = activity == .starting
        stopRecordingTimer()
        resetLevels()
        activity = .transcribing
        statusMessage = "Turning speech into text…"
        let current = sessionID
        let deliveryDestination = insertionDestination
        let pendingDestination = destinationTask
        let clipboardChangeCount = recordingClipboardChangeCount
        let test = isTestSession
        let testContinuation = activeContinuation
        let archiveContext = recordingHistory
        let dictionary = recordingDictionary
        let correctionEnabled = recordingTextCorrectionEnabled
        let language = archiveContext?.language ?? language
        let prompt = archiveContext?.prompt ?? TranscriptCleaner.vocabularyPrompt(
            (dictionary.vocabularyTerms + [vocabulary]).joined(separator: ", "))
        let clean = archiveContext?.removeFillers ?? cleanText
        transcriptionTask = Task { [weak self] in
            guard let self, current == sessionID, !Task.isCancelled else { return }
            var capturedAudio: CapturedAudio?
            var transcriptionResult: TranscriptionResult?
            var formattedText = ""
            var transcriptionStarted: TimeInterval?
            var transcriptionWallSeconds: Double?
            var archiveOutcome: DictationArchiveRecord.Outcome?
            var archiveError: String?
            var archiveDelivery: DictationDeliveryStatus?
            var textProcessing: TextProcessingRecord?
            defer {
                if let audio = capturedAudio {
                    if let context = archiveContext, let outcome = archiveOutcome,
                       current == sessionID, !Task.isCancelled {
                        if let original = audio.original {
                            let record = context.record(
                                audio: audio, original: original, releasedAt: releaseDate, completedAt: Date(),
                                outcome: outcome, result: transcriptionResult, transcript: formattedText,
                                transcriptionWallSeconds: transcriptionWallSeconds,
                                releaseToResultSeconds: ProcessInfo.processInfo.systemUptime - releasedAt,
                                deliveryStatus: archiveDelivery, errorMessage: archiveError,
                                engineVersion: engine.engineVersion, textProcessing: textProcessing
                            )
                            history.enqueue(record: record, originalAudio: original.url,
                                            transcriptionAudio: audio.url, cleanup: { audio.cleanup() })
                        } else {
                            history.reportMissingOriginal()
                            audio.cleanup()
                        }
                    } else {
                        // Cancellation/short holds and retention-off takes remain ephemeral.
                        audio.cleanup()
                    }
                }
            }
            do {
                let audio = try await recorder.stop()
                capturedAudio = audio
                guard current == sessionID, !Task.isCancelled else { return }
                guard audio.duration >= 0.25 else {
                    cancelDictation()
                    return
                }
                let processingStart = ProcessInfo.processInfo.systemUptime
                transcriptionStarted = processingStart
                let result = try await engine.transcribe(audio.url, language: language, prompt: prompt)
                transcriptionWallSeconds = ProcessInfo.processInfo.systemUptime - processingStart
                guard current == sessionID, !Task.isCancelled else { return }
                transcriptionResult = result
                let cleaned = TranscriptCleaner.clean(result.text, removeFillers: clean)
                let transcript = dictionary.apply(to: cleaned)
                guard !transcript.isEmpty else {
                    archiveOutcome = .noSpeech
                    completeWithoutText("No speech detected. Try again a little closer to the microphone.")
                    return
                }
                let capturedDestination: InsertionDestination
                if test {
                    capturedDestination = .clipboard // In-app testing never delivers.
                } else if let deliveryDestination {
                    capturedDestination = deliveryDestination
                } else {
                    capturedDestination = await pendingDestination?.value ?? .clipboard
                }
                guard current == sessionID, !Task.isCancelled else { return }
                let resolvedDestination: InsertionDestination
                if let field = capturedDestination.target,
                   !InsertionCapturePolicy.permitsInsertion(capturedAt: field.capturedAt, releasedAt: releasedAt) {
                    // Slow metadata may finish after release, but the actual
                    // focused field/caret must have been captured during the hold.
                    resolvedDestination = .clipboard
                } else {
                    resolvedDestination = capturedDestination
                }
                let target = resolvedDestination.target
                let destination = target.flatMap { $0.selection == nil ? nil : DictationDestination.field($0) }
                let previous = test ? testContinuation : destination.flatMap {
                    self.continuationMemory.continuation(for: $0, now: ProcessInfo.processInfo.systemUptime)
                }
                let structured = SpokenListFormatter.format(transcript, context: previous?.list)
                if correctionEnabled, !structured.text.isEmpty { statusMessage = "Refining text locally…" }
                let processed = try await textCorrection.process(
                    structured.text, dictionary: dictionary, dictionaryChangedText: cleaned != transcript,
                    language: result.language, enabledForTake: correctionEnabled)
                guard current == sessionID, !Task.isCancelled else { return }
                textProcessing = processed
                let formatted = structured.replacingText(processed.outputText)
                formattedText = formatted.text
                let composed = DictationComposer.compose(formatted, previous: previous)
                lastTranscript = composed.preview
                lastAudioSeconds = audio.duration
                lastTranscriptionSeconds = result.processingSeconds + (processed.processingSeconds ?? 0)
                if test {
                    continuationMemory.remember(composed.continuation, for: .test, now: ProcessInfo.processInfo.systemUptime)
                    lastDelivery = formatted.isControlOnly ? listControlMessage(formatted) + " · Nothing was pasted." : "Test complete. Nothing was pasted."
                    statusMessage = formatted.isControlOnly ? listControlMessage(formatted) : "Ready to copy"
                    lastDeliveryStatus = .tested
                } else if composed.insertion.isEmpty {
                    // Commands change only our short-lived list state. Never
                    // send an empty paste or a Return key to finish a list.
                    if let anchor = TextInserter.unchangedAnchor(target) {
                        rememberContinuation(composed.continuation, from: destination, at: .field(anchor))
                        lastDelivery = listControlMessage(formatted)
                        statusMessage = lastDelivery
                        lastDeliveryStatus = .listUpdated
                    } else {
                        lastDelivery = "List state unchanged: the original cursor could not be confirmed."
                        statusMessage = "Cursor changed"
                        lastDeliveryStatus = .unconfirmed
                    }
                } else {
                    activity = .delivering
                    switch resolvedDestination {
                    case .field: statusMessage = "Inserting your words…"
                    case .clipboard: statusMessage = "Copying to clipboard…"
                    case .blocked: statusMessage = "Keeping your words here…"
                    }
                    let outcome = await inserter.deliver(
                        composed.insertion, copying: formatted.text,
                        to: resolvedDestination,
                        clipboardUnchangedSince: clipboardChangeCount
                    )
                    guard current == sessionID, !Task.isCancelled else { return }
                    switch outcome {
                    case .inserted:
                        // Advance numbering only after delivery, and only at
                        // the exact caret left by this insertion. Editors that
                        // omit caret metadata still get formatted text, but
                        // never guessed cross-hold continuation.
                        if let anchor = inserter.confirmedAnchor {
                            rememberContinuation(composed.continuation, from: destination, at: .field(anchor))
                        } else if let destination {
                            continuationMemory.forget(destination)
                        }
                        lastDelivery = "Inserted at your cursor"
                        statusMessage = "Inserted"
                        lastDeliveryStatus = .inserted
                    case .copied(let reason):
                        lastTranscript = formatted.text
                        lastDelivery = reason
                        statusMessage = "Copied"
                        lastDeliveryStatus = .copied
                    case .unconfirmed(let clipboardBackup):
                        // An editor may have accepted the text without exposing
                        // its new caret. Never retry or guess list continuation.
                        if let destination { continuationMemory.forget(destination) }
                        lastTranscript = formatted.text
                        lastDelivery = clipboardBackup
                            ? "Insertion unconfirmed. Copied to clipboard if needed."
                            : "Insertion unconfirmed. Your words are here to copy; clipboard unchanged."
                        statusMessage = clipboardBackup ? "Copied as backup" : "Check insertion"
                        lastDeliveryStatus = .unconfirmed
                    case .failed(let reason):
                        // Copying a failed chunk must not duplicate list items
                        // that were already delivered in an earlier hold.
                        lastTranscript = formatted.text
                        lastDelivery = reason
                        statusMessage = "Ready to copy"
                        lastDeliveryStatus = .failed
                    }
                }
                activity = lastDeliveryStatus == .failed ? .failed : .success
                archiveOutcome = .transcribed
                archiveDelivery = lastDeliveryStatus
                archiveError = lastDeliveryStatus == .failed ? lastDelivery : nil
                if [.unavailable, .failed, .rejected, .skipped].contains(processed.status), !structured.isControlOnly {
                    lastDelivery += " · Text correction skipped"
                }
                destinationTask = nil
                insertionDestination = nil
                activeContinuation = nil
                recordingListHint = nil
                recordingInputName = nil
                dismissHUDAfter(seconds: lastDeliveryStatus == .failed || lastDeliveryStatus == .unconfirmed ? 4 : 1.7)
                scheduleUnload()
            } catch is CancellationError {
                settleCancelledSession(current)
            } catch EngineError.cancelled {
                settleCancelledSession(current)
            } catch AudioRecordingError.cancelled {
                settleCancelledSession(current)
            } catch AudioRecordingError.noAudio where releasedDuringStartup {
                guard current == sessionID, !Task.isCancelled else { return }
                cancelDictation()
            } catch AudioRecordingError.notRecording where releasedDuringStartup {
                guard current == sessionID, !Task.isCancelled else { return }
                cancelDictation()
            } catch {
                guard current == sessionID, !Task.isCancelled else { return }
                archiveOutcome = .failed
                archiveError = error.localizedDescription
                if let started = transcriptionStarted {
                    transcriptionWallSeconds = ProcessInfo.processInfo.systemUptime - started
                }
                showError(error.localizedDescription)
                scheduleUnload()
            }
        }
    }

    private func completeWithoutText(_ message: String) {
        showError(message)
        scheduleUnload()
    }

    private func settleCancelledSession(_ current: UUID) {
        guard current == sessionID, !Task.isCancelled else { return }
        cancelDictation()
    }

    private func prepareContinuation(for destination: DictationDestination?) {
        activeContinuation = destination.flatMap {
            continuationMemory.continuation(for: $0, now: ProcessInfo.processInfo.systemUptime)
        }
        if let list = activeContinuation?.list {
            recordingListHint = list.style == .numbered ? "Continuing at item \(list.nextNumber)" : "Continuing your list"
        } else {
            recordingListHint = nil
        }
    }

    private func rememberContinuation(_ continuation: DictationContinuation?, from previous: DictationDestination?, at next: DictationDestination) {
        if let previous { continuationMemory.forget(previous) }
        continuationMemory.remember(continuation, for: next, now: ProcessInfo.processInfo.systemUptime)
    }

    private func listControlMessage(_ formatted: FormattedDictation) -> String {
        if formatted.endedList && formatted.context == nil { return "List finished" }
        return formatted.continuesPreviousList ? "List continued" : "List started"
    }

    private func showError(_ message: String) {
        destinationTask?.cancel()
        destinationTask = nil
        insertionDestination = nil
        recordingInputName = nil
        activity = .failed
        errorMessage = message
        statusMessage = message
        onHUDVisibility?(true)
        dismissHUDAfter(seconds: 4)
    }

    private func dismissHUDAfter(seconds: Double) {
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard let self, !isBusy else { return }
            onHUDVisibility?(false)
            if activity == .success {
                activity = .idle
                statusMessage = "Ready when you are"
            }
        }
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCapturing else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - self.recordingStart
                self.recordingFeedback.updateElapsed(elapsed)
                if elapsed >= LifecyclePolicy.maximumRecordingSeconds { self.finishDictation() }
            }
        }
        timer.tolerance = 0.025
        recordingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func resetLevels() {
        recordingFeedback.clearLevels()
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        guard !isBusy, engineStatus == .ready,
              let delay = LifecyclePolicy.unloadDelay(idleMinutes: idleMinutes) else { return }
        idleTask = Task { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
            }
            guard let self, !isBusy, !Task.isCancelled else { return }
            engine.unload(reason: "Resting after inactivity")
        }
    }

    private func retryPermissions() {
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            for _ in 0..<30 {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                guard let self else { return }
                refreshPermissions()
                if allPermissionsGranted { return }
            }
        }
    }

    private func updateLoginItem() {
        guard !updatingLogin else { return }
        updatingLogin = true
        defer { updatingLogin = false }
        loginItemError = nil
        let status = SMAppService.mainApp.status
        if launchAtLogin, status == .enabled { return }
        if launchAtLogin, status == .requiresApproval {
            loginItemError = "Allow Sotto in System Settings → General → Login Items to finish enabling this preference."
            return
        }
        // A rebuilt accessory app may report .notFound even though login is
        // already off. Do not attempt to unregister an absent service.
        if !launchAtLogin, status != .enabled, status != .requiresApproval { return }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if launchAtLogin, SMAppService.mainApp.status == .requiresApproval {
                loginItemError = "Allow Sotto in System Settings → General → Login Items to finish enabling this preference."
            }
        } catch {
            // Keep the desired setting consistent between UI and JSON. A denied
            // OS operation must not trigger file rollback/retry feedback loops.
            loginItemError = "Couldn’t update launch at login: \(error.localizedDescription)"
        }
    }

    private func installLifecycleObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshPermissions() } })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.willPowerOffNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restForSystem() }
            })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.restForSystem() } }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isBusy else { return }
                self.unloadModel()
                self.textCorrection.unload()
            }
        }
        memoryPressure = pressure
        pressure.resume()
    }

    private func restForSystem() {
        stopShortcutCheck()
        cancelDictation()
        continuationMemory.removeAll()
        idleTask?.cancel()
        warmTask?.cancel()
        engine.unload(reason: "Resting while your Mac is away")
        textCorrection.unload()
    }
}
