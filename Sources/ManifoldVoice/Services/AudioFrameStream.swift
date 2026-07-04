import Foundation

/// A source of captured microphone frames used to monitor for user speech
/// **while the assistant is speaking** (barge-in).
///
/// It is deliberately separate from ``SpeechTranscribing``: the transcriber runs
/// *after* a barge-in to capture the actual utterance, so the monitor and the
/// transcriber never run concurrently and don't contend for one audio engine.
///
/// The production ``AVAudioEngineFrameStream`` taps the input node with echo
/// cancellation enabled; a test double replays a scripted frame sequence.
public protocol AudioFrameStream: AnyObject {
    /// Begin delivering captured frames to `onFrame` on the main actor. Throws if
    /// capture can't start (for example in the simulator or on an audio-session
    /// failure). Calling it again after a successful start first stops the prior
    /// capture.
    @MainActor
    func startCapturing(onFrame: @escaping @MainActor (AudioFrame) -> Void) throws

    /// Stop delivering frames and release capture resources. Idempotent — safe to
    /// call when not capturing.
    @MainActor
    func stopCapturing()
}
