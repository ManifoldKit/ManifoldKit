import Foundation

public struct SpeechTranscriptionUpdate: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public struct WakeWordDetection: Sendable, Equatable {
    public let phrase: String
    public let transcript: String

    public init(phrase: String, transcript: String) {
        self.phrase = phrase
        self.transcript = transcript
    }
}

public enum VoiceAuthorizationStatus: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unsupportedLocale
    case microphoneDenied
}

public enum VoiceCaptureState: Equatable {
    case idle
    case requestingPermission
    case recording
    case processing
    case failed(String)
}

public enum VoiceError: LocalizedError, Equatable {
    case recognizerUnavailable
    case unsupportedLocale
    case speechRecognitionDenied
    case speechRecognitionRestricted
    case microphoneAccessDenied
    case simulatorUnsupported
    case setupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            "Speech recognition is unavailable right now."
        case .unsupportedLocale:
            "Speech recognition is unavailable for the current locale."
        case .speechRecognitionDenied:
            "Speech recognition permission is required for voice input."
        case .speechRecognitionRestricted:
            "Speech recognition is restricted on this device."
        case .microphoneAccessDenied:
            "Microphone access is required for voice input."
        case .simulatorUnsupported:
            "Voice capture is unavailable in the simulator."
        case .setupFailed(let message):
            "Voice capture could not start: \(message)"
        }
    }
}

public protocol SpeechTranscribing: AnyObject {
    @MainActor
    func requestAuthorization() async -> VoiceAuthorizationStatus

    @MainActor
    func startTranscribing(
        onUpdate: @escaping @MainActor (SpeechTranscriptionUpdate) -> Void
    ) async throws

    @MainActor
    func stopTranscribing() async throws -> String?

    @MainActor
    func cancelTranscribing()
}

/// Voice/rate/pitch/language controls for a single spoken utterance.
///
/// A default-initialised `SpeechOptions()` reproduces the historical behaviour:
/// system-default voice, default speech rate, no pitch adjustment.
///
/// - `rate`: Apple's `AVSpeechUtterance.rate`, valid in the range
///   `AVSpeechUtteranceMinimumSpeechRate ... AVSpeechUtteranceMaximumSpeechRate`
///   around `AVSpeechUtteranceDefaultSpeechRate`. `nil` uses the default.
/// - `pitchMultiplier`: `AVSpeechUtterance.pitchMultiplier`, valid in `0.5 ... 2.0`
///   (1.0 is normal pitch). `nil` leaves the system default.
/// - `voiceIdentifier`: an `AVSpeechSynthesisVoice` identifier; `nil` falls back to
///   `locale` (if set) or the system default.
/// - `locale`: a BCP-47 language code (for example `"en-US"`) used to pick a voice
///   when `voiceIdentifier` is `nil`.
public struct SpeechOptions: Sendable, Equatable {
    public var voiceIdentifier: String?
    public var rate: Float?
    public var pitchMultiplier: Float?
    public var locale: String?

    public init(
        voiceIdentifier: String? = nil,
        rate: Float? = nil,
        pitchMultiplier: Float? = nil,
        locale: String? = nil
    ) {
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
        self.pitchMultiplier = pitchMultiplier
        self.locale = locale
    }
}

public protocol SpeechSynthesizing: AnyObject {
    /// Speak `text` in replace mode with default options — the historical core
    /// requirement. Custom voice engines that don't need queueing or voice
    /// control conform by implementing just this method.
    @MainActor
    func speak(_ text: String) async throws

    /// Speak `text` with the given `options`.
    ///
    /// - Parameter enqueue: when `false` (the historical behaviour) any in-flight
    ///   utterance is cancelled and replaced. When `true` the utterance is appended
    ///   to the queue and plays after the current one finishes — the basis for
    ///   continuous read-aloud of a sequence of items.
    ///
    /// A default implementation forwards to ``speak(_:)`` (replace mode, options
    /// ignored), so engines without queueing/voice support still conform without
    /// implementing this. Engines that support it (``AppleSpeechSynthesizer``)
    /// override it.
    @MainActor
    func speak(_ text: String, options: SpeechOptions, enqueue: Bool) async throws

    @MainActor
    func stopSpeaking()
}

// Both `speak` requirements carry a default that forwards to the other, so a
// conformer satisfies the protocol by implementing EITHER one — historical
// engines via `speak(_:)`, queue-aware engines via the options-aware method.
public extension SpeechSynthesizing {
    /// Default for the options/queueing API: replace mode, options ignored.
    @MainActor
    func speak(_ text: String, options: SpeechOptions, enqueue: Bool) async throws {
        try await speak(text)
    }

    /// Source-compatible shim for the original single-string API: replace mode,
    /// default options.
    @MainActor
    func speak(_ text: String) async throws {
        try await speak(text, options: SpeechOptions(), enqueue: false)
    }
}

/// A "now speaking this range" progress update, emitted as an utterance is
/// spoken so hosts can do read-along highlighting or resume from a known
/// position.
public struct SpeechProgress: Sendable, Equatable {
    /// Identifies the utterance this update belongs to. The synthesizer can hold
    /// several queued utterances; the id is stable for one `speak(...)` call and
    /// changes when the next utterance begins, letting a host tell read-along of
    /// one item apart from the next.
    public let utteranceID: UUID

    /// The full text of the utterance currently being spoken.
    public let text: String

    /// The range within ``text`` currently being spoken. It indexes into the
    /// `text` carried on this same value, so the pair is always self-consistent
    /// — safe to use directly for highlighting `Text(text)`.
    public let spokenRange: Range<String.Index>

    /// The substring currently being spoken — `text[spokenRange]`.
    public var spokenText: String { String(text[spokenRange]) }

    public init(utteranceID: UUID, text: String, spokenRange: Range<String.Index>) {
        self.utteranceID = utteranceID
        self.text = text
        self.spokenRange = spokenRange
    }
}

/// Optional capability for synthesizers that report spoken-range progress as
/// they speak (Apple's `willSpeakRangeOfSpeechString`). Hosts that want
/// read-along highlighting or resume-from-position check `as? SpeechProgressReporting`
/// and set ``onSpeechProgress``. Engines without range reporting simply don't
/// conform — callers degrade to no highlighting rather than breaking.
public protocol SpeechProgressReporting: AnyObject {
    /// Invoked on the main actor for each spoken range as the current utterance
    /// progresses. `nil` (the default) disables reporting.
    @MainActor
    var onSpeechProgress: (@MainActor (SpeechProgress) -> Void)? { get set }
}

public protocol WakeWordDetector: AnyObject {
    @MainActor
    func ingest(_ update: SpeechTranscriptionUpdate) -> WakeWordDetection?

    @MainActor
    func reset()
}
