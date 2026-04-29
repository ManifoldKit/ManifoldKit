import Foundation

@MainActor
public final class AppleWakeWordDetector: WakeWordDetector {
    private struct PhraseMatcher: Equatable {
        let original: String
        let normalized: String
    }

    private let phrases: [PhraseMatcher]
    private var hasTriggered = false

    public init(wakeWords: [String]) {
        self.phrases = wakeWords.compactMap { phrase in
            let normalized = Self.normalize(phrase)
            guard !normalized.isEmpty else { return nil }
            return PhraseMatcher(original: phrase, normalized: normalized)
        }
    }

    public func ingest(_ update: SpeechTranscriptionUpdate) -> WakeWordDetection? {
        guard !hasTriggered else { return nil }

        let normalizedTranscript = Self.normalize(update.text)
        guard !normalizedTranscript.isEmpty else { return nil }

        let paddedTranscript = " \(normalizedTranscript) "
        for phrase in phrases {
            if paddedTranscript.contains(" \(phrase.normalized) ") {
                hasTriggered = true
                return WakeWordDetection(phrase: phrase.original, transcript: update.text)
            }
        }

        return nil
    }

    public func reset() {
        hasTriggered = false
    }

    private static func normalize(_ text: String) -> String {
        let lowercased = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let cleanedScalars = lowercased.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }

        return String(cleanedScalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
