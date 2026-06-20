@preconcurrency import AVFoundation
import Foundation

/// A selectable text-to-speech voice, decoupled from `AVFoundation` so UI and
/// tests can reason about voices without importing the speech framework.
///
/// Produced by ``AppleTTSBackend/availableVoices(language:)`` and consumed by
/// voice pickers. The ``id`` is the platform voice identifier a caller stores
/// in ``SpeechGenerationConfig/voice`` to pin a specific voice.
public struct VoiceDescriptor: Sendable, Codable, Hashable, Identifiable {

    /// Render quality tier. Apple ships three tiers; the higher two
    /// (`enhanced`, `premium`) are downloadable on-device and dramatically more
    /// natural than the always-resident `standard` (compact) voices.
    public enum Quality: Int, Sendable, Codable, Hashable, Comparable, CaseIterable {
        /// Always-resident "compact" voice — the robotic floor.
        case standard = 1
        /// Downloadable higher-fidelity voice.
        case enhanced = 2
        /// Downloadable neural voice — the most natural tier.
        case premium = 3

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// Human-facing label for grouping in a picker.
        public var displayName: String {
            switch self {
            case .standard: return "Standard"
            case .enhanced: return "Enhanced"
            case .premium: return "Premium"
            }
        }
    }

    /// Platform voice identifier (e.g. `com.apple.voice.premium.en-US.Ava`).
    /// Store this in ``SpeechGenerationConfig/voice`` to pin the voice.
    public let id: String

    /// Human-readable voice name (e.g. `Ava`).
    public let name: String

    /// BCP-47 language tag the voice speaks (e.g. `en-US`).
    public let language: String

    /// Render-quality tier.
    public let quality: Quality

    public init(id: String, name: String, language: String, quality: Quality) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }
}

extension VoiceDescriptor.Quality {
    /// Maps Apple's `AVSpeechSynthesisVoiceQuality` onto our tier. Unknown
    /// future raw values fall back to `standard` rather than trapping.
    init(_ avQuality: AVSpeechSynthesisVoiceQuality) {
        switch avQuality {
        case .premium: self = .premium
        case .enhanced: self = .enhanced
        default: self = .standard
        }
    }
}

extension VoiceDescriptor {
    /// Bridges an `AVSpeechSynthesisVoice` into the framework-free descriptor.
    init(_ voice: AVSpeechSynthesisVoice) {
        self.init(
            id: voice.identifier,
            name: voice.name,
            language: voice.language,
            quality: Quality(voice.quality)
        )
    }
}
