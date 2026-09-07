import AppKit
import AVFAudio
import AudioToolbox
import Foundation
import SottoCore
import ServiceManagement

@MainActor
enum SottoCommandLine {
    static func run(_ arguments: [String]) async -> Int32 {
        if arguments == ["--diagnostics"] {
            let permissions = PermissionSnapshot.capture()
            let hardware = AudioInputHardware.snapshot()
            let available = hardware.inputs.map(\.device)
            let defaultUID = hardware.inputs.first { $0.deviceID == hardware.systemDefaultID }?.device.uid
            let file = ConfigurationFile()
            let configResult = await file.read()
            let saved = (try? configResult.get())?.microphones ?? MicrophonePreferences()
            let input = MicrophoneSelectionPolicy.resolve(preferences: saved, available: available, systemDefaultUID: defaultUID)
            printJSON([
                "app": "Sotto", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                "permissionScope": "Current launch context. Terminal-launched checks may be attributed to the terminal; the app window is authoritative.",
                "modelPath": SottoPaths().model.path,
                "modelPresent": FileManager.default.fileExists(atPath: SottoPaths().model.path),
                "microphone": permissions.microphone,
                "accessibility": permissions.accessibility,
                "inputMonitoring": permissions.inputMonitoring,
                "audioInputs": available.map { device in
                    ["name": device.name, "transport": device.transport.rawValue,
                     "systemDefault": device.uid == defaultUID] as [String: Any]
                },
                "nextMicrophone": input.device?.name ?? "No microphone available",
                "microphonePriorityList": saved.activeProfile.name,
                "configurationPath": file.url.path,
                "configurationValid": (try? configResult.get()) != nil,
            ])
            return 0
        }
        if arguments == ["--prepare-config"] {
            let configuration = ConfigurationStore(legacyLoginEnabled: SMAppService.mainApp.status == .enabled)
            await configuration.start()
            await configuration.flush()
            configuration.stopWatching()
            if let error = configuration.errorMessage {
                printJSON(["error": error])
                return 1
            }
            printJSON(["configurationPath": configuration.url.path])
            return 0
        }
        if arguments == ["--prepare-history"] {
            switch await DictationArchiveWriter().prepare() {
            case .success(let directory):
                printJSON(["historyPath": directory.path])
                return 0
            case .failure(let error):
                printJSON(["error": error.localizedDescription])
                return 1
            }
        }
        if arguments.first == "--import-text-model" {
            guard arguments.count == 2, !arguments[1].isEmpty, !arguments[1].hasPrefix("--") else { return 2 }
            let source = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true)
            let store = TextModelStore()
            switch await store.importVerified(from: source) {
            case .success:
                printJSON(["modelPath": store.paths.model.path, "modelID": TextModel.qwen.id,
                           "modelSHA256": TextModel.qwen.sha256])
                return 0
            case .failure(let error):
                printJSON(["error": error.localizedDescription])
                return 1
            }
        }
        if arguments.first == "--correct-text" {
            guard arguments.count == 2 || (arguments.count == 4 && arguments[2] == "--config") else { return 2 }
            do {
                let file = ConfigurationFile(url: arguments.count == 4 ? URL(fileURLWithPath: arguments[3]) : nil)
                let settings = try await file.read().get()
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: arguments[1]))
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 32_769) ?? Data()
                guard data.count <= 32_768, let source = String(data: data, encoding: .utf8) else {
                    throw EngineError.unavailable("Supply a UTF-8 transcript smaller than 32 KB.")
                }
                let service = await correctionService(settings: settings, file: file)
                defer { service.shutdown() }
                let cleaned = TranscriptCleaner.clean(source, removeFillers: settings.cleanText)
                let dictionaryText = settings.dictionary.apply(to: cleaned)
                let formatted = SpokenListFormatter.format(dictionaryText)
                let result = try await service.process(formatted.text, dictionary: settings.dictionary,
                    dictionaryChangedText: cleaned != dictionaryText, language: settings.language,
                    enabledForTake: settings.textCorrectionEnabled)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
                return 0
            } catch {
                printJSON(["error": error.localizedDescription])
                return 1
            }
        }
        guard let options = transcriptionOptions(arguments) else {
            print("""
            Sotto — local macOS dictation

            Open Sotto.app for the menu-bar app.
            Sotto --diagnostics
            Sotto --transcribe /path/to/mono-16khz.wav [--json] [--archive-root /path/to/archive] [--config /path/to/config.json]
            Sotto --correct-text /path/to/transcript.txt [--config /path/to/config.json]
            Sotto --import-text-model /path/to/pinned-mlx-model-folder
            Sotto --prepare-history
            Sotto --prepare-config

            --transcribe uses the speech engine and list cleanup; --config also applies dictionary/text correction.
            --correct-text uses the dictionary and optional local text model without speech recognition.
            --config and --correct-text read preferences without changing them or downloading models.
            It never captures your microphone or pastes text.
            File transcription saves no history unless --archive-root is supplied.
            --prepare-history only creates the private ~/.murmur/transcripts folder.
            --prepare-config migrates legacy preferences only when config.json is missing.
            --import-text-model copies and verifies the pinned MLX files into ~/.murmur/models without downloading.
            """)
            return arguments == ["--help"] ? 0 : 2
        }
        let paths = SottoPaths()
        let integrity = await Task.detached(priority: .userInitiated) { ModelIntegrity.verify(paths.model) }.value
        if case .failure(let error) = integrity {
            printJSON(["error": error.localizedDescription])
            return 1
        }
        let engine = EngineClient(paths: paths)
        defer { engine.unload(reason: "Command finished") }
        var correction: TextCorrectionService?
        defer { correction?.shutdown() }
        do {
            let configFile = ConfigurationFile(url: options.config)
            let settings = options.config == nil
                ? SottoConfiguration(dictionary: PersonalDictionary(lists: []), textCorrectionEnabled: false)
                : try await configFile.read().get()
            let prompt = TranscriptCleaner.vocabularyPrompt((settings.dictionary.vocabularyTerms + [settings.vocabulary]).joined(separator: ", "))
            if options.config != nil { correction = await correctionService(settings: settings, file: configFile) }
            let audioFormat = try options.archiveRoot.map { _ in try archiveAudioFormat(options.audio) }
            let submittedAt = Date()
            let loadStart = ProcessInfo.processInfo.systemUptime
            try await engine.ensureLoaded()
            let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
            let transcriptionStart = ProcessInfo.processInfo.systemUptime
            let result = try await engine.transcribe(options.audio, language: settings.language, prompt: prompt)
            let transcriptionWallSeconds = ProcessInfo.processInfo.systemUptime - transcriptionStart
            let cleaned = TranscriptCleaner.clean(result.text, removeFillers: settings.cleanText)
            let dictionaryText = settings.dictionary.apply(to: cleaned)
            let formatted = SpokenListFormatter.format(dictionaryText).text
            let textProcessing = try await correction?.process(formatted, dictionary: settings.dictionary,
                dictionaryChangedText: cleaned != dictionaryText, language: result.language,
                enabledForTake: settings.textCorrectionEnabled)
            let text = textProcessing?.outputText ?? formatted
            let completedAt = Date()
            var output: [String: Any] = [
                "text": text, "audioSeconds": result.audioSeconds,
                "transcriptionSeconds": result.processingSeconds,
                "coldLoadSeconds": loadSeconds, "language": result.language,
                "enginePID": engine.processIdentifier ?? 0,
            ]
            if let textProcessing {
                output["textProcessing"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(textProcessing))
            }
            if let root = options.archiveRoot, let audioFormat {
                let model = SpeechModel.turbo
                let record = DictationArchiveRecord(
                    id: UUID(), startedAt: submittedAt, releasedAt: submittedAt, completedAt: completedAt,
                    mode: .file, outcome: text.isEmpty ? .noSpeech : .transcribed,
                    rawText: result.text, transcriptText: text,
                    model: .init(id: model.id, name: model.name, sha256: model.sha256,
                                 engine: "whisper.cpp", engineVersion: engine.engineVersion ?? "unknown"),
                    options: .init(requestedLanguage: settings.language, detectedLanguage: result.language,
                                   removeFillers: settings.cleanText, vocabularyPrompt: prompt),
                    microphone: .init(uid: nil, name: nil),
                    audio: .init(original: audioFormat, transcription: audioFormat),
                    timing: .init(engineProcessingSeconds: result.processingSeconds,
                                  transcriptionWallSeconds: transcriptionWallSeconds,
                                  releaseToResultSeconds: ProcessInfo.processInfo.systemUptime - loadStart),
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                    appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                    textProcessing: textProcessing
                )
                let archive = await DictationArchiveWriter(root: root).save(
                    record: record, originalAudio: options.audio, transcriptionAudio: options.audio
                )
                switch archive {
                case .success(let directory):
                    output["archivePath"] = directory.path
                case .failure(let error):
                    output["archiveError"] = error.localizedDescription
                    printJSON(output)
                    return 1
                }
            }
            if options.json { printJSON(output) }
            else { print(text) }
            return 0
        } catch {
            printJSON(["error": error.localizedDescription])
            return 1
        }
    }

    private static func correctionService(settings: SottoConfiguration, file: ConfigurationFile) async -> TextCorrectionService {
        let store = TextModelStore()
        if settings.textCorrectionEnabled { _ = await store.verifyInstalled() }
        // No startup/migration/watch for command-line snapshots. These commands
        // never write the user's config or register a login item/hotkey.
        return TextCorrectionService(configuration: ConfigurationStore(file: file), modelStore: store, inspectOnInit: false)
    }

    private static func transcriptionOptions(_ arguments: [String]) -> (audio: URL, json: Bool, archiveRoot: URL?, config: URL?)? {
        guard arguments.count >= 2, arguments[0] == "--transcribe",
              !arguments[1].isEmpty, !arguments[1].hasPrefix("--") else { return nil }
        var json = false
        var archiveRoot: URL?
        var config: URL?
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--json" where !json:
                json = true
            case "--archive-root" where archiveRoot == nil:
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty,
                      !arguments[index].hasPrefix("--") else { return nil }
                archiveRoot = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath,
                                  isDirectory: true)
            case "--config" where config == nil:
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty,
                      !arguments[index].hasPrefix("--") else { return nil }
                config = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
            default:
                return nil
            }
            index += 1
        }
        return (URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath), json, archiveRoot, config)
    }

    private static func archiveAudioFormat(_ url: URL) throws -> DictationArchiveRecord.AudioFormat {
        let file = try AVAudioFile(forReading: url)
        // fileFormat describes bytes on disk; processingFormat may convert PCM16 to float32.
        let format = file.fileFormat
        let stream = format.streamDescription.pointee
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw EngineError.unavailable("The input audio format could not be read.")
        }
        let sampleFormat: String
        if stream.mFormatID == kAudioFormatLinearPCM {
            let kind = stream.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "f"
                : (stream.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 ? "s" : "u")
            let endian = stream.mFormatFlags & kAudioFormatFlagIsBigEndian != 0 ? "be" : "le"
            sampleFormat = "pcm_\(kind)\(stream.mBitsPerChannel)\(endian)"
        } else {
            sampleFormat = "format_id_\(stream.mFormatID)"
        }
        return .init(sampleRate: format.sampleRate, channels: Int(format.channelCount),
                     sampleFormat: sampleFormat, frameCount: file.length,
                     durationSeconds: Double(file.length) / format.sampleRate)
    }

    private static func printJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return }
        print(string)
    }
}
