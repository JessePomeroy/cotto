import Foundation

public enum TranscriptCleaner {
    /// Deliberately not an LLM rewrite: keep the speaker’s meaning, names, and wording.
    public static func clean(_ raw: String, removeFillers: Bool = true) -> String {
        let silenceMarkers = ["[BLANK_AUDIO]", "[NO_SPEECH]", "[SILENCE]", "(silence)", "[Music]", "[MUSIC]"]
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if silenceMarkers.contains(where: { text.caseInsensitiveCompare($0) == .orderedSame }) { return "" }
        text = text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
        if removeFillers {
            // Only unambiguous hesitation sounds. Never strip “like”, “you know”, or repetitions.
            text = text.replacingOccurrences(of: #"(?i)(?<![\p{L}\p{N}])(?:um+|uh+|erm)(?:,\s*|\s+)(?=[\p{L}\p{N}])"#, with: "", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func vocabularyPrompt(_ vocabulary: String) -> String {
        vocabulary.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(80)
            .joined(separator: ", ")
            .prefix(1_024)
            .description
    }
}
