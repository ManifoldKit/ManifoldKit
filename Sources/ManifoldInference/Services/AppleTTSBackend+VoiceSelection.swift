@preconcurrency import AVFoundation
import Foundation

// MARK: - Voice enumeration + quality-aware selection
//
// Why this exists: leaving `AVSpeechUtterance.voice` nil (or resolving a
// language tag via `AVSpeechSynthesisVoice(language:)`) yields the *compact*
// default — e.g. `com.apple.voice.compact.en-US.Samantha`, the robotic floor.
// Worse, the legacy MacinTalk novelty voices (Zarvox, Bells, Boing…) share the
// same `standard` quality tier as Samantha, so a naive `max(by: quality)` can
// surface a joke voice. The ranking below prefers the modern Siri-family voices
// and the highest installed quality tier (premium → enhanced → compact), so the
// backend automatically uses a downloaded Premium voice the moment one exists.

extension AppleTTSBackend {

    /// Installed speech voices as framework-free ``VoiceDescriptor`` values,
    /// sorted best-first (premium → enhanced → standard; modern Siri voices
    /// ahead of legacy/novelty voices at equal quality).
    ///
    /// - Parameter language: BCP-47 tag (or bare primary subtag like `"en"`)
    ///   to filter by. `nil` returns every installed voice.
    public static func availableVoices(language: String? = nil) -> [VoiceDescriptor] {
        let descriptors = AVSpeechSynthesisVoice.speechVoices()
            .map(VoiceDescriptor.init)
            .filter { language == nil || Self.languageMatches($0.language, language!) }
        return Self.ranked(descriptors)
    }

    /// Resolves the concrete `AVSpeechSynthesisVoice` for a config, applying the
    /// quality-aware fallback. An explicit voice *identifier* always wins; a
    /// language tag (or nil) resolves to the best installed voice for that
    /// language (or the device language when nil).
    static func resolveVoice(config: SpeechGenerationConfig) -> AVSpeechSynthesisVoice? {
        guard let requested = config.voice, !requested.isEmpty else {
            return bestVoice(forLanguage: nil)
        }
        // A real identifier resolves directly; a language tag does not, so it
        // falls through to the quality-aware language path.
        if let exact = AVSpeechSynthesisVoice(identifier: requested) {
            return exact
        }
        return bestVoice(forLanguage: requested)
            ?? AVSpeechSynthesisVoice(language: requested)
    }

    /// Highest-ranked installed voice for a language, or the device language
    /// when `language` is nil. Returns nil only when no voice is installed.
    static func bestVoice(forLanguage language: String?) -> AVSpeechSynthesisVoice? {
        let target = language ?? AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices()

        // Prefer an exact language match; fall back to the primary subtag
        // (e.g. device "en-AU" can borrow a premium "en-US" before settling for
        // a compact "en-AU").
        let exact = voices.filter { $0.language.caseInsensitiveCompare(target) == .orderedSame }
        let pool = exact.isEmpty
            ? voices.filter { Self.languageMatches($0.language, target) }
            : exact

        return pool.max { Self.score(VoiceDescriptor($0)) < Self.score(VoiceDescriptor($1)) }
    }

    // MARK: - Pure ranking (unit-testable without AVFoundation voices)

    /// Sorts descriptors best-first using ``score(_:)``, with a stable
    /// alphabetical tie-break so equal-scoring voices order deterministically.
    static func ranked(_ descriptors: [VoiceDescriptor]) -> [VoiceDescriptor] {
        descriptors.sorted { lhs, rhs in
            let sl = score(lhs), sr = score(rhs)
            if sl != sr { return sl > sr }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Heuristic desirability score. Quality dominates; within a tier the modern
    /// Siri family (`com.apple.voice.*`) is preferred over super-compact, legacy
    /// MacinTalk novelty (`com.apple.speech.synthesis.voice.*`), and Eloquence
    /// voices — so a compact Samantha outranks Zarvox despite equal quality.
    static func score(_ voice: VoiceDescriptor) -> Int {
        var s = voice.quality.rawValue * 1000
        let id = voice.id
        if id.contains(".voice.") { s += 100 }                       // modern Siri family
        if id.contains(".super-compact.") { s -= 60 }                // lower fidelity than compact
        if id.hasPrefix("com.apple.eloquence.") { s -= 200 }         // robotic
        if id.hasPrefix("com.apple.speech.synthesis.voice.") { s -= 500 } // MacinTalk novelty
        return s
    }

    /// True when `voiceLanguage` matches `query` exactly or shares its primary
    /// subtag (so `"en"` matches `"en-US"` and `"en-GB"`).
    static func languageMatches(_ voiceLanguage: String, _ query: String) -> Bool {
        if voiceLanguage.caseInsensitiveCompare(query) == .orderedSame { return true }
        let primary: (String) -> String = { $0.split(separator: "-").first.map(String.init)?.lowercased() ?? "" }
        let pv = primary(voiceLanguage)
        return !pv.isEmpty && pv == primary(query)
    }
}
