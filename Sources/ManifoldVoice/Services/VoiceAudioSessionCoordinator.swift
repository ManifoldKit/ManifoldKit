@preconcurrency import AVFoundation
#if os(iOS)
import UIKit
#endif

@MainActor
final class VoiceAudioSessionCoordinator {
    func activateRecording() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // When VoiceOver is running, omit `.duckOthers`: ducking would attenuate
        // VoiceOver's own speech output, leaving the screen-reader user fighting
        // a quieted assistant. Record without ducking so VoiceOver stays audible.
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
        if !UIAccessibility.isVoiceOverRunning {
            options.insert(.duckOthers)
        }
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: options
        )
        try session.setActive(true)
        #endif
    }

    /// Activate a full-duplex session for barge-in monitoring: capture the mic
    /// *while* the synthesizer is playing, with acoustic echo cancellation so the
    /// assistant's own output is removed from the input before a detector sees it.
    ///
    /// `.voiceChat` mode is the switch that turns on Apple's built-in AEC — it is
    /// the primary self-barge-in mitigation. On macOS there is no `AVAudioSession`
    /// (echo cancellation is handled by the OS audio stack), so this is a no-op
    /// and the shared deactivation applies only on iOS.
    ///
    /// - Note: barge-in arms this *during* playback, so on iOS the shared session
    ///   category/mode is reconfigured while `AVSpeechSynthesizer` is already
    ///   speaking. Whether that briefly glitches the in-flight utterance is
    ///   route-dependent runtime behavior — a device-validation item, not
    ///   observable in `swift test`.
    func activateDuplex() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true)
        #endif
    }

    func deactivateRecording() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
