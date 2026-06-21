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

    func deactivateRecording() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
