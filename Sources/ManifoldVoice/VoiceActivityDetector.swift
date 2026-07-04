import Foundation

/// A voice-activity transition emitted by a ``VoiceActivityDetector`` as it
/// consumes a stream of ``AudioFrame``s.
public enum VoiceActivity: Sendable, Equatable {
    /// The detector judged that speech just began (silence → speech).
    case speechStart
    /// The detector judged that speech just ended (speech → silence).
    case speechEnd
}

/// Detects speech onset/offset from a stream of audio frames.
///
/// Injected into ``VoiceConversationController`` to drive barge-in: while the
/// assistant is speaking, a `.speechStart` interrupts playback and hands off to
/// recording. Conformers are stateful (they track a silence/speech run) and live
/// on the main actor alongside the controller.
///
/// The default ``EnergyVoiceActivityDetector`` is zero-dependency. A model-backed
/// detector (for example Silero) can conform without any controller change — the
/// controller depends only on this protocol.
public protocol VoiceActivityDetector: AnyObject {
    /// Feed one frame; returns a transition the instant the detector crosses its
    /// onset/offset threshold, otherwise `nil`.
    @MainActor
    func ingest(_ frame: AudioFrame) -> VoiceActivity?

    /// Reset all accumulated state back to "silence". Called when monitoring
    /// stops so the next session starts clean.
    @MainActor
    func reset()
}
