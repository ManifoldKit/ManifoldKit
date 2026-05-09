@preconcurrency import AVFoundation

protocol VoiceAudioSessionCoordinating: AnyObject {
    @MainActor
    func activateRecording() throws

    @MainActor
    func deactivateRecording()
}

@MainActor
final class DefaultVoiceAudioSessionCoordinator: VoiceAudioSessionCoordinating {
    func activateRecording() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .duckOthers]
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
