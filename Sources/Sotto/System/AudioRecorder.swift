import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import SottoCore
import SottoAudioBridge
import OSLog

struct CapturedAudio: Sendable {
    let url: URL
    let duration: TimeInterval
    /// Absolute sample peak, in the range 0...1 for normal microphone audio.
    let peak: Float
    /// Unmixed, unresampled PCM delivered by the microphone's input tap.
    let original: OriginalCapturedAudio?
    fileprivate let directory: URL

    /// The caller owns the recording after stop() succeeds, including its deletion.
    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Startup cleanup also recognizes captures from before the Sotto rename.
    /// Only generated capture names in the temporary folder qualify; archives are untouched.
    static func cleanupOrphans(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            let isCapture = ["Sotto-recording-", "Murmur-recording-"].contains { prefix in
                name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            }
            if isCapture { try? files.removeItem(at: entry) }
        }
    }
}

struct OriginalCapturedAudio: Sendable {
    let url: URL
    let sampleRate: Double
    let channelCount: UInt32
    let frameCount: Int64
    /// WAV storage uses the input tap's PCM precision in little-endian order.
    let encoding: String
}

enum AudioRecordingError: LocalizedError {
    case permissionRequired
    case alreadyRecording
    case notRecording
    case microphoneUnavailable
    case microphoneSelectionFailed(OSStatus)
    case conversionUnavailable
    case noAudio
    case cancelled
    case processing(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "Allow microphone access in System Settings first."
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "There is no recording to finish."
        case .microphoneUnavailable: "The selected microphone is unavailable. Choose another input in Sotto."
        case .microphoneSelectionFailed(let status): "This microphone could not be opened (audio error \(status)). Choose another input in Sotto."
        case .conversionUnavailable: "This microphone's audio format could not be converted. Try another input device."
        case .noAudio: "The microphone did not provide any audio."
        case .cancelled: "The recording was cancelled."
        case .processing(let message): "Could not save microphone audio: \(message)"
        }
    }
}

/// Owns the hardware only between explicit start() and stop()/cancel() calls.
@MainActor
final class AudioRecorder {
    var onLevel: ((Float) -> Void)?
    var onInterruption: ((String) -> Void)?

    private let worker: AudioCaptureWorker
    private let microphoneAuthorized: () -> Bool
    private let sleepNotifications: NotificationCenter
    private var request: AudioCaptureRequest?
    private var sleepObserver: NSObjectProtocol?

    init(worker: AudioCaptureWorker? = nil,
         microphoneAuthorized: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
         sleepNotifications: NotificationCenter? = nil) {
        self.worker = worker ?? AudioCaptureWorker(makeHardware: { QueuedAudioHardware(queue: $0) })
        self.microphoneAuthorized = microphoneAuthorized
        self.sleepNotifications = sleepNotifications ?? NSWorkspace.shared.notificationCenter
    }

    func start(deviceID: AudioDeviceID? = nil, preserveOriginalAudio: Bool = false) async throws {
        guard request == nil else { throw AudioRecordingError.alreadyRecording }
        guard microphoneAuthorized() else { throw AudioRecordingError.permissionRequired }
        guard !Task.isCancelled else { throw AudioRecordingError.cancelled }
        let current = AudioCaptureRequest()
        request = current
        sleepObserver = sleepNotifications.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interrupt(id: current.id, message: "Recording stopped because your Mac is going to sleep.")
            }
        }
        do {
            try await worker.start(
                request: current, deviceID: deviceID,
                preserveOriginalAudio: preserveOriginalAudio,
                onLevel: { [weak self] level in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.request?.id == current.id, current.acceptsAudio else { return }
                        self.onLevel?(level)
                    }
                },
                onInterruption: { [weak self] message in
                    DispatchQueue.main.async { [weak self] in
                        self?.interrupt(id: current.id, message: message)
                    }
                }
            )
            guard !Task.isCancelled else {
                worker.cancel(request: current)
                throw AudioRecordingError.cancelled
            }
        } catch {
            // A release can race a slow startup failure. Retain that request
            // until stop() consumes it, so a quick hold becomes noAudio rather
            // than accidentally stopping or publishing into a later take.
            if request?.id == current.id, !current.isReleased {
                request = nil
                removeSleepObserver()
                onLevel?(0)
            }
            throw error
        }
    }

    /// Call directly on key release, before scheduling the async stop task.
    /// No tap arriving after this gate closes may admit additional PCM.
    func stopAcceptingAudio() {
        request?.release()
        onLevel?(0)
    }

    func stop() async throws -> CapturedAudio {
        guard let current = request else { throw AudioRecordingError.notRecording }
        current.release()
        request = nil
        removeSleepObserver()
        onLevel?(0)
        return try await worker.stop(request: current)
    }

    func cancel() {
        let current = request
        current?.cancel()
        request = nil
        removeSleepObserver()
        onLevel?(0)
        if let current { worker.cancel(request: current) }
    }

    private func interrupt(id: UUID, message: String) {
        guard request?.id == id else { return }
        cancel()
        onInterruption?(message)
    }

    private func removeSleepObserver() {
        if let sleepObserver { sleepNotifications.removeObserver(sleepObserver) }
        sleepObserver = nil
    }

    deinit {
        if let request { worker.cancel(request: request) }
        if let sleepObserver { sleepNotifications.removeObserver(sleepObserver) }
    }
}

/// All mutable engine state, HAL setup, and teardown stay on the worker's queue.
/// Notification callbacks only enqueue work; the audio tap owns no UI state.
private final class QueuedAudioHardware: AudioCaptureHardware, @unchecked Sendable {
    private let queue: DispatchQueue
    private var engine: AVAudioEngine?
    private var writer: RecordingWriter?
    private var request: AudioCaptureRequest?
    private var onInterruption: (@Sendable (String) -> Void)?
    private var recordingID: UUID?
    private var configurationObserver: NSObjectProtocol?
    private var deviceObservers: [AudioDeviceObservation] = []
    private var pinnedInput: PinnedRecordingInput?
    private var tapInstalled = false

    init(queue: DispatchQueue) { self.queue = queue }

    func start(request: AudioCaptureRequest, deviceID: AudioDeviceID?, preserveOriginalAudio: Bool,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable (String) -> Void) throws {
        try request.requireOpen()
        guard writer == nil else { throw AudioRecordingError.alreadyRecording }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRecordingError.permissionRequired
        }
        // Resolve even "System default" once. A newly connected preferred mic
        // applies to the next hold, never halfway through the current recording.
        guard var selectedDevice = deviceID ?? AudioInputHardware.defaultInputID(),
              AudioInputHardware.isAvailable(selectedDevice) else {
            throw AudioRecordingError.microphoneUnavailable
        }
        try request.requireOpen()

        let engine = AVAudioEngine()
        self.engine = engine
        self.request = request
        self.onInterruption = onInterruption
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw AudioRecordingError.microphoneUnavailable }
        // This changes only this engine's input AudioUnit, not the system device.
        // Bind before asking for a format: USB, Bluetooth, virtual, and built-in
        // inputs can all have different channel counts and sample rates.
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &selectedDevice, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw AudioRecordingError.microphoneSelectionFailed(status) }
        guard Self.currentDevice(of: input) == selectedDevice else { throw AudioRecordingError.microphoneUnavailable }
        // After selecting a device, the client/output format may still belong
        // to the previous route. Always capture the actual hardware PCM format.
        let format = try SottoAudioBridge.inputFormat(for: input)
        try request.requireOpen()

        let id = request.id
        let writer = try RecordingWriter(
            inputFormat: format,
            preserveOriginalAudio: preserveOriginalAudio,
            onLevel: onLevel,
            onError: { [weak self] message in
                self?.enqueueInterruption(id: id, message: message)
            }
        )

        self.writer = writer
        recordingID = id
        pinnedInput = PinnedRecordingInput(deviceID: selectedDevice, format: format)

        // Mark the attempt so failure cleanup also removes a partially installed
        // tap. The Objective-C bridge contains AVFAudio exceptions, including a
        // format renegotiation racing this call; Swift catch alone cannot.
        tapInstalled = true
        try SottoAudioBridge.installTap(on: input, format: format) { buffer, _ in
            if request.acceptsAudio { writer.append(buffer) }
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // AVAudioEngine explicitly forbids deallocating the engine inside
            // this notification's internal callback (it can deadlock).
            self?.enqueueRouteCheck(id: id)
        }
        deviceObservers = [
            AudioDeviceObservation.observe(selectedDevice, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
            AudioDeviceObservation.observe(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
        ].compactMap { $0 }

        try request.requireOpen()
        try SottoAudioBridge.prepare(engine)
        try request.requireOpen()
        try SottoAudioBridge.start(engine)
        guard !request.isCancelled else { throw AudioRecordingError.cancelled }
        // The engine must not silently replace a requested route during
        // preparation. Fail this take rather than record the wrong source.
        guard engine.isRunning,
              Self.currentDevice(of: input) == selectedDevice,
              try SottoAudioBridge.inputFormat(for: input) == format,
              AudioInputHardware.isAvailable(selectedDevice) else {
            throw AudioRecordingError.microphoneUnavailable
        }
    }

    func stop() -> RecordingWriter? {
        request?.release()
        let currentWriter = writer
        detachMicrophone()
        return currentWriter
    }

    func cancel() {
        // Failure cleanup must not turn an already released take into a new
        // cancellation; stop() still needs to consume its admitted PCM/noAudio.
        request?.release()
        let currentWriter = writer
        detachMicrophone()
        currentWriter?.cancel()
    }

    private func enqueueRouteCheck(id: UUID) {
        queue.async { [weak self] in self?.checkPinnedInput(id: id) }
    }

    private func enqueueInterruption(id: UUID, message: String) {
        queue.async { [weak self] in self?.interrupt(id: id, message: message) }
    }

    private func interrupt(id: UUID, message: String) {
        guard recordingID == id, request?.acceptsAudio == true else { return }
        let callback = onInterruption
        request?.cancel()
        cancel()
        callback?(message)
    }

    private func checkPinnedInput(id: UUID) {
        guard recordingID == id, request?.acceptsAudio == true, let pinnedInput, let engine else { return }
        let input = engine.inputNode
        guard let currentFormat = try? SottoAudioBridge.inputFormat(for: input) else {
            interrupt(id: id, message: "The microphone’s audio format changed. Please try again.")
            return
        }
        let action = pinnedInput.action(
            currentDeviceID: Self.currentDevice(of: input),
            currentFormat: currentFormat,
            isAvailable: AudioInputHardware.isAvailable(pinnedInput.deviceID),
            engineIsRunning: engine.isRunning
        )
        switch action {
        case .keepRecording:
            break // Other devices/defaults changed; this input is unaffected.
        case .restartPinnedInput:
            do {
                try request?.requireOpen()
                try SottoAudioBridge.start(engine)
                guard pinnedInput.action(
                    currentDeviceID: Self.currentDevice(of: input),
                    currentFormat: try SottoAudioBridge.inputFormat(for: input),
                    isAvailable: AudioInputHardware.isAvailable(pinnedInput.deviceID),
                    engineIsRunning: engine.isRunning
                ) == .keepRecording else {
                    throw AudioRecordingError.microphoneUnavailable
                }
            } catch {
                interrupt(id: id, message: "The microphone stopped. Please try again.")
            }
        case .interrupt:
            interrupt(id: id, message: "The recording microphone changed or disconnected. Please try again.")
        }
    }

    private static func currentDevice(of input: AVAudioInputNode) -> AudioDeviceID? {
        guard let unit = input.audioUnit else { return nil }
        var device: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private func detachMicrophone() {
        recordingID = nil
        pinnedInput = nil
        deviceObservers.forEach { $0.cancel() }
        deviceObservers.removeAll()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let engine {
            do { try SottoAudioBridge.stop(engine, removeInputTap: tapInstalled) }
            catch {
                Logger(subsystem: "dev.davis.murmur", category: "audio-capture")
                    .error("Audio teardown failed: \(String(describing: error), privacy: .public)")
            }
        }
        tapInstalled = false
        engine = nil
        writer = nil
        request = nil
        onInterruption = nil
    }

    deinit { cancel() }
}

/// Ignore unrelated hardware changes, and restart only the same usable route
/// with the same PCM format. Switching sources/formats requires a new take.
struct PinnedRecordingInput {
    enum Action: Equatable { case keepRecording, restartPinnedInput, interrupt }

    let deviceID: AudioDeviceID
    let format: AVAudioFormat

    func action(currentDeviceID: AudioDeviceID?, currentFormat: AVAudioFormat, isAvailable: Bool, engineIsRunning: Bool) -> Action {
        guard isAvailable, currentDeviceID == deviceID, currentFormat == format else { return .interrupt }
        return engineIsRunning ? .keepRecording : .restartPinnedInput
    }
}

/// Only the admission gate is shared between the audio callback and the caller.
/// Converter, file, counters, and errors are confined to the serial writer queue.
final class RecordingWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.sotto.audio-writer", qos: .userInitiated)
    private let admissionLock = NSLock()
    private var accepting = true

    private let directory: URL
    private let url: URL
    private let originalURL: URL?
    private let format: AVAudioFormat
    private let converter: AVAudioConverter
    private let onLevel: (Float) -> Void
    private let onError: (String) -> Void
    private var file: AVAudioFile?
    private var originalFile: AVAudioFile?
    private var failure: Error?
    private var frames: AVAudioFramePosition = 0
    private var inputFrames: AVAudioFramePosition = 0
    private var peak: Float = 0
    private var meter = AudioLevelMeter()
    private var meterSumSquares = 0.0
    private var meterFrames = 0
    private let meterWindowFrames = 800 // 50 ms at the WAV's 16 kHz sample rate.

    init(inputFormat: AVAudioFormat, preserveOriginalAudio: Bool = false,
         onLevel: @escaping (Float) -> Void, onError: @escaping (String) -> Void) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw AudioRecordingError.conversionUnavailable
        }
        self.format = format
        self.converter = converter
        self.onLevel = onLevel
        self.onError = onError
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sotto-recording-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("microphone.wav")
        originalURL = preserveOriginalAudio ? directory.appendingPathComponent("original.wav") : nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try queue.sync {
                file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                if let originalURL {
                    // WAV interleaves channels on disk, but no samples are mixed or
                    // resampled. AVAudioFile accepts the tap's original buffer layout.
                    var settings = inputFormat.settings
                    settings[AVLinearPCMIsNonInterleaved] = false
                    settings[AVLinearPCMIsBigEndianKey] = false
                    originalFile = try AVAudioFile(
                        forWriting: originalURL, settings: settings,
                        commonFormat: inputFormat.commonFormat, interleaved: inputFormat.isInterleaved
                    )
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalURL.path)
                }
            }
        } catch {
            file = nil
            originalFile = nil
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func append(_ source: AVAudioPCMBuffer) {
        // AVAudioEngine reuses its buffers. Copy only PCM memory here; never run
        // conversion, metering, UI work, or disk I/O on the real-time callback.
        guard source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (sourceBuffer, destinationBuffer) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else { continue }
            memcpy(destinationData, sourceData, Int(min(sourceBuffer.mDataByteSize, destinationBuffer.mDataByteSize)))
        }

        admissionLock.lock()
        if accepting {
            queue.async { [self] in process(copy) }
        }
        admissionLock.unlock()
    }

    func finish() async throws -> CapturedAudio {
        try await withCheckedThrowingContinuation { continuation in
            admissionLock.lock()
            guard accepting else {
                admissionLock.unlock()
                continuation.resume(throwing: AudioRecordingError.cancelled)
                return
            }
            accepting = false
            queue.async { [self] in
                do {
                    if let failure { throw failure }
                    try flushConverter()
                    guard frames > 0 else { throw AudioRecordingError.noAudio }
                    file = nil // Close and finalize the WAV header before handing it off.
                    originalFile = nil
                    let original = originalURL.map {
                        let inputFormat = converter.inputFormat
                        let descriptor = inputFormat.streamDescription.pointee
                        let precision = descriptor.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "f" : "s"
                        return OriginalCapturedAudio(
                            url: $0, sampleRate: inputFormat.sampleRate,
                            channelCount: inputFormat.channelCount, frameCount: inputFrames,
                            encoding: "pcm_\(precision)\(descriptor.mBitsPerChannel)le"
                        )
                    }
                    continuation.resume(returning: CapturedAudio(
                        url: url, duration: Double(frames) / format.sampleRate, peak: peak,
                        original: original, directory: directory
                    ))
                } catch {
                    discardFile()
                    continuation.resume(throwing: error)
                }
            }
            admissionLock.unlock()
        }
    }

    func cancel() {
        admissionLock.lock()
        if accepting {
            accepting = false
            queue.async { [self] in discardFile() }
        }
        admissionLock.unlock()
    }

    private func process(_ input: AVAudioPCMBuffer) {
        guard failure == nil else { return }
        guard input.format == converter.inputFormat else {
            fail(AudioRecordingError.microphoneUnavailable)
            return
        }
        // Bound both files to the same admitted input interval. This also avoids
        // converting late driver buffers after the three-minute cap is reached.
        let remainingInputFrames = AVAudioFramePosition(input.format.sampleRate * 180) - inputFrames
        guard remainingInputFrames > 0 else { return }
        input.frameLength = min(input.frameLength, AVAudioFrameCount(remainingInputFrames))
        do {
            try originalFile?.write(from: input)
            inputFrames += AVAudioFramePosition(input.frameLength)
        } catch {
            fail(error)
            return
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            fail(AudioRecordingError.conversionUnavailable)
            return
        }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            fail(conversionError ?? AudioRecordingError.conversionUnavailable as NSError)
            return
        }
        do {
            try write(output)
        } catch {
            fail(error)
        }
    }

    private func flushConverter() throws {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw AudioRecordingError.conversionUnavailable
        }
        // A bounded flush avoids hanging shutdown on a malfunctioning converter.
        for _ in 0..<8 {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error { throw conversionError ?? AudioRecordingError.conversionUnavailable as NSError }
            try write(output)
            if status == .endOfStream || status == .inputRanDry || output.frameLength == 0 { return }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0], let file else { return }
        // The controller stops the microphone at 180 seconds, but its timer can
        // run one callback late. Keep the WAV within the helper's strict limit.
        let remainingFrames = AVAudioFramePosition(format.sampleRate * 180) - frames
        guard remainingFrames > 0 else { return }
        buffer.frameLength = min(buffer.frameLength, AVAudioFrameCount(remainingFrames))
        try file.write(from: buffer)
        for index in 0..<Int(buffer.frameLength) {
            let sample = samples[index]
            let magnitude = sample.isFinite ? abs(sample) : 0
            peak = max(peak, magnitude)
            // Sanitize only the measurement; the PCM written above is untouched.
            let measured = Double(min(1, magnitude))
            meterSumSquares += measured * measured
            meterFrames += 1
            if meterFrames == meterWindowFrames {
                let rms = sqrt(meterSumSquares / Double(meterFrames))
                onLevel(meter.update(rms: rms, frameCount: meterFrames, sampleRate: format.sampleRate))
                meterSumSquares = 0
                meterFrames = 0
            }
        }
        frames += AVAudioFramePosition(buffer.frameLength)
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        onError(error.localizedDescription)
    }

    private func discardFile() {
        file = nil
        originalFile = nil
        try? FileManager.default.removeItem(at: directory)
    }
}
