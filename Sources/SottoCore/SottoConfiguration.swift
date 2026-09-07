import Foundation

/// The editable preferences in ~/.murmur/config.json. System permissions and window state
/// belong to macOS, rather than this configuration.
public struct SottoConfiguration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var holdKey: String
    public var language: String
    public var idleMinutes: Int
    public var cleanText: Bool
    public var vocabulary: String
    public var launchAtLogin: Bool
    public var saveDictationHistory: Bool
    public var microphones: MicrophonePreferences
    public var dictionary: PersonalDictionary
    public var textCorrectionEnabled: Bool

    public static let `default` = SottoConfiguration()
    public static let supportedLanguages = [
        "en", "auto", "es", "fr", "de", "it", "pt", "nl", "ja", "zh", "ko", "hi", "ar", "pl", "ru", "uk", "sv",
    ]

    public init(holdKey: String = "rightOption", language: String = "en", idleMinutes: Int = 5,
                cleanText: Bool = true, vocabulary: String = "", launchAtLogin: Bool = false,
                saveDictationHistory: Bool = true, microphones: MicrophonePreferences = MicrophonePreferences(),
                dictionary: PersonalDictionary = .default, textCorrectionEnabled: Bool = true) {
        schemaVersion = 1
        self.holdKey = holdKey
        self.language = language
        self.idleMinutes = idleMinutes
        self.cleanText = cleanText
        self.vocabulary = vocabulary
        self.launchAtLogin = launchAtLogin
        self.saveDictationHistory = saveDictationHistory
        self.microphones = microphones
        self.dictionary = dictionary
        self.textCorrectionEnabled = textCorrectionEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, holdKey, language, idleMinutes, cleanText, vocabulary
        case launchAtLogin, saveDictationHistory, microphones, dictionary, textCorrectionEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.value(Int.self, for: .schemaVersion, default: 1)
        guard version == 1 else {
            throw values.invalid(.schemaVersion, "Only schemaVersion 1 is supported.")
        }
        let holdKey = try values.value(String.self, for: .holdKey, default: "rightOption")
        guard ["rightOption", "rightControl", "fn"].contains(holdKey) else {
            throw values.invalid(.holdKey, "Use rightOption, rightControl, or fn.")
        }
        let language = try values.value(String.self, for: .language, default: "en")
        guard Self.supportedLanguages.contains(language) else {
            throw values.invalid(.language, "Use a supported language code: \(Self.supportedLanguages.joined(separator: ", ")).")
        }
        let idleMinutes = try values.value(Int.self, for: .idleMinutes, default: 5)
        guard [-1, 0, 5, 15].contains(idleMinutes) else {
            throw values.invalid(.idleMinutes, "Use -1 (keep loaded), 0, 5, or 15 minutes.")
        }
        self.init(holdKey: holdKey, language: language, idleMinutes: idleMinutes,
                  cleanText: try values.value(Bool.self, for: .cleanText, default: true),
                  vocabulary: try values.value(String.self, for: .vocabulary, default: ""),
                  launchAtLogin: try values.value(Bool.self, for: .launchAtLogin, default: false),
                  saveDictationHistory: try values.value(Bool.self, for: .saveDictationHistory, default: true),
                  microphones: values.contains(.microphones)
                    ? try values.decode(StrictMicrophones.self, forKey: .microphones).preferences
                    : MicrophonePreferences(),
                  dictionary: try values.value(PersonalDictionary.self, for: .dictionary, default: .default),
                  textCorrectionEnabled: try values.value(Bool.self, for: .textCorrectionEnabled, default: true))
    }
}

// Legacy microphone preferences intentionally salvage damaged UserDefaults records. A
// hand-edited config must instead reject mistakes without silently losing a priority list.
private struct StrictMicrophones: Decodable {
    let preferences: MicrophonePreferences
    private enum CodingKeys: String, CodingKey { case profiles, activeProfileID, selection }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let profiles = values.contains(.profiles)
            ? try values.decode([StrictProfile].self, forKey: .profiles).map(\.profile)
            : [.defaultProfile]
        guard !profiles.isEmpty, Set(profiles.map(\.id)).count == profiles.count else {
            throw values.invalid(.profiles, "Provide at least one profile, with a unique nonempty id for each.")
        }
        let activeID = try values.value(String.self, for: .activeProfileID, default: profiles[0].id)
        guard profiles.contains(where: { $0.id == activeID }) else {
            throw values.invalid(.activeProfileID, "The activeProfileID must match a profile id.")
        }
        let selection = values.contains(.selection)
            ? try values.decode(StrictSelection.self, forKey: .selection).selection : .automatic
        var preferences = MicrophonePreferences()
        preferences.profiles = profiles
        preferences.activeProfileID = activeID
        preferences.selection = selection
        self.preferences = preferences
    }
}

private struct StrictProfile: Decodable {
    let profile: MicrophoneProfile
    private enum CodingKeys: String, CodingKey { case id, name, priority }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        let name = try values.value(String.self, for: .name, default: "Default")
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw values.invalid(.id, "Profile ids and names must not be empty.")
        }
        let priority = values.contains(.priority)
            ? try values.decode([StrictDevice].self, forKey: .priority).map(\.device) : []
        guard Set(priority.map(\.uid)).count == priority.count else {
            throw values.invalid(.priority, "Each microphone UID must appear only once in a priority list.")
        }
        profile = MicrophoneProfile(id: id, name: name, priority: priority)
    }
}

private struct StrictDevice: Decodable {
    let device: AudioInputDevice
    private enum CodingKeys: String, CodingKey { case uid, name, transport }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let uid = try values.decode(String.self, forKey: .uid)
        let name = try values.value(String.self, for: .name, default: "Microphone")
        let rawTransport = try values.value(String.self, for: .transport, default: "other")
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw values.invalid(.uid, "Microphone UIDs and names must not be empty.")
        }
        guard let transport = AudioInputTransport(rawValue: rawTransport) else {
            throw values.invalid(.transport, "Use builtIn, usb, bluetooth, virtual, aggregate, or other.")
        }
        device = AudioInputDevice(uid: uid, name: name, transport: transport)
    }
}

private struct StrictSelection: Decodable {
    let selection: MicrophoneSelection
    private enum CodingKeys: String, CodingKey { case mode, device }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.value(String.self, for: .mode, default: "automatic") {
        case "automatic": selection = .automatic
        case "systemDefault": selection = .systemDefault
        case "fixed": selection = .fixed(try values.decode(StrictDevice.self, forKey: .device).device)
        default: throw values.invalid(.mode, "Use automatic, systemDefault, or fixed.")
        }
    }
}

private extension KeyedDecodingContainer {
    /// A missing key chooses its default; an explicit null or wrong type is an error.
    func value<Value: Decodable>(_ type: Value.Type, for key: Key, default fallback: Value) throws -> Value {
        contains(key) ? try decode(type, forKey: key) : fallback
    }

    func invalid(_ key: Key, _ message: String) -> DecodingError {
        .dataCorruptedError(forKey: key, in: self, debugDescription: message)
    }
}
