import Foundation
@_exported import SottoDomain

public enum SottoAPI {
    public static let version = 1
    public static let defaultPort = 8391
    public static let maximumRecordingSeconds = 180
    public static let maximumChunkBytes = 1_048_576
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct DeviceIdentity: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct ServerPreferences: Codable, Equatable, Sendable {
    public var language: String
    public var cleanText: Bool
    public var vocabulary: String
    public var dictionary: PersonalDictionary
    public var textCorrectionEnabled: Bool
    public var keepOriginalAudio: Bool
    public static let supportedLanguages = ["en", "auto", "es", "fr", "de", "it", "pt", "nl", "ja", "zh", "ko", "hi", "ar", "pl", "ru", "uk", "sv"]
    public init(language: String = "en", cleanText: Bool = true, vocabulary: String = "",
                dictionary: PersonalDictionary = .default, textCorrectionEnabled: Bool = true,
                keepOriginalAudio: Bool = true) {
        self.language = language; self.cleanText = cleanText; self.vocabulary = vocabulary
        self.dictionary = dictionary; self.textCorrectionEnabled = textCorrectionEnabled
        self.keepOriginalAudio = keepOriginalAudio
    }
    public var validationError: String? {
        if !Self.supportedLanguages.contains(language) { return "Choose a supported language." }
        if vocabulary.utf8.count > 16_384 || vocabulary.contains("\0") { return "Vocabulary must fit within 16 KB and contain no null characters." }
        return dictionary.validationError
    }
}

public struct PreferencesSnapshot: Codable, Equatable, Sendable {
    public var revision: Int
    public var preferences: ServerPreferences
    public init(revision: Int = 0, preferences: ServerPreferences = .init()) {
        self.revision = revision; self.preferences = preferences
    }
}

public struct ModelRuntimeInfo: Codable, Equatable, Sendable {
    public var modelID: String
    public var backend: String
    public var ready: Bool
    public var message: String?
    public init(modelID: String, backend: String, ready: Bool, message: String? = nil) {
        self.modelID = modelID; self.backend = backend; self.ready = ready; self.message = message
    }
}

public struct ServerHealth: Codable, Equatable, Sendable {
    public var apiVersion: Int
    public var serverVersion: String
    public var isDev: Bool
    public var ready: Bool
    public var speech: ModelRuntimeInfo
    public var proofreading: ModelRuntimeInfo
    public var message: String?
    public init(apiVersion: Int = SottoAPI.version, serverVersion: String = "0.1.0", isDev: Bool = true,
                ready: Bool, speech: ModelRuntimeInfo, proofreading: ModelRuntimeInfo, message: String? = nil) {
        self.apiVersion = apiVersion; self.serverVersion = serverVersion; self.isDev = isDev
        self.ready = ready; self.speech = speech; self.proofreading = proofreading; self.message = message
    }
}

public enum GenerationMode: String, Codable, Sendable { case dictation, test, file }
public enum GenerationStatus: String, Codable, Sendable {
    case receiving, queued, transcribing, proofreading, completed, failed, cancelled
    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}
public enum AudioKind: String, Codable, Sendable { case inference, original }

public struct CreateGenerationRequest: Codable, Sendable {
    public var requestID: UUID
    public var device: DeviceIdentity
    public var mode: GenerationMode
    public init(requestID: UUID = UUID(), device: DeviceIdentity, mode: GenerationMode = .dictation) {
        self.requestID = requestID; self.device = device; self.mode = mode
    }
}

public struct AudioStreamFormat: Codable, Equatable, Sendable {
    public var sampleRate: Int
    public var channels: Int
    public init(sampleRate: Int, channels: Int) { self.sampleRate = sampleRate; self.channels = channels }
}

public struct AudioChunkReceipt: Codable, Sendable {
    public var nextSequence: Int
    public var frameCount: Int64
    public init(nextSequence: Int, frameCount: Int64) { self.nextSequence = nextSequence; self.frameCount = frameCount }
}

public struct FinishGenerationRequest: Codable, Sendable {
    public var inferenceFrames: Int64
    public var originalFrames: Int64?
    public var continuationID: UUID?
    public init(inferenceFrames: Int64, originalFrames: Int64? = nil, continuationID: UUID? = nil) {
        self.inferenceFrames = inferenceFrames; self.originalFrames = originalFrames; self.continuationID = continuationID
    }
}

public struct AudioArtifact: Codable, Equatable, Sendable {
    public var filename: String
    public var sampleRate: Int
    public var channels: Int
    public var frameCount: Int64
    public var byteCount: Int64
    public var encoding: String
    public var duration: Double { Double(frameCount) / Double(max(1, sampleRate)) }
    public init(filename: String, sampleRate: Int, channels: Int, frameCount: Int64, byteCount: Int64, encoding: String = "pcm_f32le") {
        self.filename = filename; self.sampleRate = sampleRate; self.channels = channels
        self.frameCount = frameCount; self.byteCount = byteCount; self.encoding = encoding
    }
}

public struct ModelProvenance: Codable, Equatable, Sendable {
    public var modelID: String
    public var modelSHA256: String?
    public var backend: String
    public var engineVersion: String?
    public var processingSeconds: Double?
    public init(modelID: String, modelSHA256: String? = nil, backend: String, engineVersion: String? = nil, processingSeconds: Double? = nil) {
        self.modelID = modelID; self.modelSHA256 = modelSHA256; self.backend = backend
        self.engineVersion = engineVersion; self.processingSeconds = processingSeconds
    }
}

public struct DeliveryReceipt: Codable, Equatable, Sendable {
    public var status: String
    public var message: String?
    public var reportedAt: Date
    public init(status: String, message: String? = nil, reportedAt: Date = Date()) {
        self.status = status; self.message = message; self.reportedAt = reportedAt
    }
}

public struct GenerationRecord: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var id: UUID
    public var requestID: UUID
    public var device: DeviceIdentity
    public var mode: GenerationMode
    public var status: GenerationStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var settings: PreferencesSnapshot
    public var inferenceAudio: AudioArtifact?
    public var originalAudio: AudioArtifact?
    public var rawText: String
    public var finalText: String
    public var insertionText: String
    public var previewText: String
    public var detectedLanguage: String?
    public var speech: ModelProvenance?
    public var proofreading: ModelProvenance?
    public var textProcessing: TextProcessingRecord?
    public var continuation: DictationContinuation?
    public var delivery: DeliveryReceipt?
    public var error: String?
    public var progress: Double?
    public var audioSeconds: Double { inferenceAudio?.duration ?? 0 }
    public init(id: UUID = UUID(), requestID: UUID, device: DeviceIdentity, mode: GenerationMode = .dictation,
                status: GenerationStatus = .receiving, createdAt: Date = Date(), settings: PreferencesSnapshot) {
        schemaVersion = 1; self.id = id; self.requestID = requestID; self.device = device; self.mode = mode
        self.status = status; self.createdAt = createdAt; updatedAt = createdAt; self.settings = settings
        rawText = ""; finalText = ""; insertionText = ""; previewText = ""
    }
}

public struct GenerationPage: Codable, Sendable {
    public var items: [GenerationRecord]
    public var nextCursor: String?
    public init(items: [GenerationRecord], nextCursor: String? = nil) { self.items = items; self.nextCursor = nextCursor }
}

public struct APIErrorResponse: Codable, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}
