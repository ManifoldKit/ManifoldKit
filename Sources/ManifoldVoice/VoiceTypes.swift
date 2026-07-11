import Foundation

public struct SpeechTranscriptionUpdate: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
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

/// A non-blaming, recoverable outcome surfaced to the user instead of a dead-end
/// failure string. Lets the view offer the right affordance:
/// - `.openSettings`: permission was actively refused/restricted — the only path
///   forward is the system Settings app, so the view shows an "Open Settings"
///   button wired to ``VoiceConversationController/openSystemSettings()``.
/// - `.requestAgain`: permission was never asked (`notDetermined`) — tapping the
///   mic again re-triggers the OS prompt, so we say "tap to allow" rather than
///   telling the user they were denied.
/// - `.retry`: a transient miss ("didn't catch that") — just try again.
public enum VoiceRecoveryAffordance: Sendable, Equatable {
    case openSettings
    case requestAgain
    case retry
}

public enum VoiceError: LocalizedError, Equatable {
    case recognizerUnavailable
    case unsupportedLocale
    case speechRecognitionDenied
    case speechRecognitionNotDetermined
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
        case .speechRecognitionNotDetermined:
            "Tap to allow microphone and speech access for voice input."
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

public extension SpeechTranscribing {
    /// Stream-based alternative to ``startTranscribing(onUpdate:)`` for callers
    /// that prefer `for try await` consumption over a callback closure.
    ///
    /// This is a thin adapter over the callback API — it does not introduce a
    /// second transcription pipeline. Unlike ``ManifoldContract/GenerationStream``
    /// (which layers idle-timeout detection, phase tracking, and stall callbacks
    /// on top of its base stream), transcription has no equivalent cross-cutting
    /// concern to justify a bespoke wrapper type: a plain `AsyncThrowingStream`
    /// is the whole story. The callback-based API remains the source of truth;
    /// callback removal is a deliberate breaking-change wave, not part of this
    /// addition (see issue #2157).
    ///
    /// The stream finishes normally when an update arrives with
    /// ``SpeechTranscriptionUpdate/isFinal`` set to `true`, or with the thrown
    /// error if ``startTranscribing(onUpdate:)`` fails. Cancelling iteration
    /// (or letting the stream's task fall out of scope) calls
    /// ``cancelTranscribing()`` on the receiver.
    ///
    /// ```swift
    /// for try await update in transcriber.transcriptionUpdates() {
    ///     print(update.text, update.isFinal)
    /// }
    /// ```
    @MainActor
    func transcriptionUpdates() -> AsyncThrowingStream<SpeechTranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            // `self` (the generic, protocol-constrained `Self`) is not statically
            // provable `Sendable`, so it cannot be captured `[weak self]` inside
            // `onTermination`, which is `@Sendable`. Route cancellation through
            // this `Task` handle instead — `Task<Void, Never>` is `Sendable` on
            // its own, and `self` stays captured strongly inside the one
            // `@MainActor` closure literal that formed it, which is fine.
            let task = Task { @MainActor in
                do {
                    try await startTranscribing { update in
                        continuation.yield(update)
                        if update.isFinal {
                            continuation.finish()
                        }
                    }
                    // `startTranscribing` only awaits setup (registering the
                    // tap/callback), not completion, so this task must stay
                    // alive until torn down — `Task.sleep` throws
                    // `CancellationError` the instant `onTermination` below
                    // cancels `task`.
                    try await Task.sleep(nanoseconds: .max)
                } catch is CancellationError {
                    cancelTranscribing()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // `continuation.finish()` (e.g. from the `isFinal` branch above)
            // also triggers `onTermination`, which cancels this already-finished
            // task — a harmless no-op re-entry into the `catch is
            // CancellationError` branch.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
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
