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
    /// Speak `text` with the given `options`.
    ///
    /// - Parameter enqueue: when `false` (the historical behaviour) any in-flight
    ///   utterance is cancelled and replaced. When `true` the utterance is appended
    ///   to the queue and plays after the current one finishes — the basis for
    ///   continuous read-aloud of a sequence of items.
    @MainActor
    func speak(_ text: String, options: SpeechOptions, enqueue: Bool) async throws

    @MainActor
    func stopSpeaking()
}

public extension SpeechSynthesizing {
    /// Source-compatible shim for the original single-string API: replace mode,
    /// default options.
    @MainActor
    func speak(_ text: String) async throws {
        try await speak(text, options: SpeechOptions(), enqueue: false)
    }
}

public protocol WakeWordDetector: AnyObject {
    @MainActor
    func ingest(_ update: SpeechTranscriptionUpdate) -> WakeWordDetection?

    @MainActor
    func reset()
}
