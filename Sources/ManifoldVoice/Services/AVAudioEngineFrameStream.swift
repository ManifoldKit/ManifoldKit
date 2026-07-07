@preconcurrency import AVFoundation
import Foundation

/// Production ``AudioFrameStream`` backed by `AVAudioEngine`'s input tap.
///
/// Runs only while the assistant is speaking (barge-in monitoring), so it never
/// overlaps the transcriber's own engine. It activates the `.voiceChat` audio
/// session mode via ``VoiceAudioSessionCoordinator`` — enabling Apple's acoustic
/// echo cancellation so the synthesizer's output is largely removed from the mic
/// before frames reach the detector, the primary self-barge-in mitigation.
///
/// Echo cancellation is best-effort: residual bleed is further guarded by the
/// controller refusing to feed frames when it isn't actively monitoring.
@MainActor
public final class AVAudioEngineFrameStream: AudioFrameStream {

    private let audioSessionCoordinator: VoiceAudioSessionCoordinator
    private let frameDuration: Double
    private var engine: AVAudioEngine?

    /// - Parameter frameDuration: target seconds of audio per delivered frame; the
    ///   tap buffer size is derived from the hardware sample rate. ~20 ms is a
    ///   typical VAD frame and the default.
    public init(frameDuration: Double = 0.02) {
        self.audioSessionCoordinator = VoiceAudioSessionCoordinator()
        self.frameDuration = frameDuration
    }

    init(
        frameDuration: Double = 0.02,
        audioSessionCoordinator: VoiceAudioSessionCoordinator
    ) {
        self.audioSessionCoordinator = audioSessionCoordinator
        self.frameDuration = frameDuration
    }

    public func startCapturing(onFrame: @escaping @MainActor (AudioFrame) -> Void) throws {
        #if targetEnvironment(simulator)
        // The simulator has no real microphone; capture would silently deliver
        // nothing. Fail loudly so a host arming barge-in in the simulator learns
        // it's unsupported rather than waiting forever for an onset.
        throw VoiceError.simulatorUnsupported
        #else
        stopCapturing()

        try audioSessionCoordinator.activateDuplex()

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let bufferSize = AVAudioFrameCount(max(256, sampleRate * frameDuration))

        input.removeTap(onBus: 0)
        // The tap fires on a non-main audio thread. Following AppleSpeechTranscriber,
        // build the block in a nonisolated static factory so it isn't @MainActor-
        // bound, convert the buffer to a Sendable AudioFrame off-main, then hop to
        // the main actor to deliver it.
        input.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: format,
            block: Self.makeTapBlock(sampleRate: sampleRate, onFrame: onFrame)
        )

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopCapturing()
            throw VoiceError.setupFailed(error.localizedDescription)
        }
        #endif
    }

    public func stopCapturing() {
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        audioSessionCoordinator.deactivateRecording()
    }

    private nonisolated static func makeTapBlock(
        sampleRate: Double,
        onFrame: @escaping @MainActor (AudioFrame) -> Void
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            guard let frame = AudioFrame(downmixing: buffer, sampleRate: sampleRate) else { return }
            Task { @MainActor in onFrame(frame) }
        }
    }
}

private extension AudioFrame {
    /// Downmix an `AVAudioPCMBuffer` to a mono ``AudioFrame``. Returns `nil` for a
    /// non-float or empty buffer.
    init?(downmixing buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frameLength)
        for channel in 0..<channelCount {
            let data = channelData[channel]
            for sample in 0..<frameLength { mono[sample] += data[sample] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for sample in 0..<frameLength { mono[sample] *= scale }
        }
        self.init(samples: mono, sampleRate: sampleRate, isEcho: false)
    }
}
