import XCTest
@testable import ManifoldVoice

// MARK: - EnergyVoiceActivityDetector (unit)

@MainActor
final class EnergyVoiceActivityDetectorTests: XCTestCase {

    /// A frame with RMS `amplitude` and a mid-band zero-crossing rate (blocks of
    /// three same-sign samples → ~0.33 ZCR, inside the plausible-speech band).
    private func voicedFrame(amplitude: Float, count: Int = 480) -> AudioFrame {
        var samples = [Float]()
        samples.reserveCapacity(count)
        var sign: Float = 1
        for index in 0..<count {
            if index % 3 == 0 { sign = -sign }
            samples.append(sign * amplitude)
        }
        return AudioFrame(samples: samples, sampleRate: 48_000)
    }

    private func silenceFrame() -> AudioFrame { voicedFrame(amplitude: 0.001) }

    func test_sustainedSpeech_emitsSpeechStartOnlyAfterOnsetCount() {
        let vad = EnergyVoiceActivityDetector() // onsetFrameCount default 3
        XCTAssertNil(vad.ingest(voicedFrame(amplitude: 0.3)))
        XCTAssertNil(vad.ingest(voicedFrame(amplitude: 0.3)))
        XCTAssertEqual(vad.ingest(voicedFrame(amplitude: 0.3)), .speechStart)
    }

    func test_interruptedRun_resetsOnsetCounter_hysteresis() {
        let vad = EnergyVoiceActivityDetector()
        XCTAssertNil(vad.ingest(voicedFrame(amplitude: 0.3))) // 1
        XCTAssertNil(vad.ingest(silenceFrame()))              // breaks the run
        XCTAssertNil(vad.ingest(voicedFrame(amplitude: 0.3))) // 1 again
        // Two consecutive speech frames must NOT be enough — onset needs three.
        XCTAssertNil(vad.ingest(voicedFrame(amplitude: 0.3))) // 2
    }

    func test_constantToneRejectedByZeroCrossingBand() {
        let vad = EnergyVoiceActivityDetector()
        // A loud DC-ish tone (no sign changes → ZCR 0) is above the energy
        // threshold but outside the plausible-speech ZCR band, so it must never
        // trigger onset — guards against a hum/feedback barging in.
        let dc = AudioFrame(samples: Array(repeating: 0.5, count: 480), sampleRate: 48_000)
        for _ in 0..<10 { XCTAssertNil(vad.ingest(dc)) }
    }

    func test_speechThenSilence_emitsSpeechEndAfterOffsetCount() {
        let vad = EnergyVoiceActivityDetector() // offsetFrameCount default 8
        for _ in 0..<3 { _ = vad.ingest(voicedFrame(amplitude: 0.3)) } // now in speech
        for _ in 0..<7 { XCTAssertNil(vad.ingest(silenceFrame())) }
        XCTAssertEqual(vad.ingest(silenceFrame()), .speechEnd)
    }

    func test_reset_clearsSpeechState() {
        let vad = EnergyVoiceActivityDetector()
        for _ in 0..<3 { _ = vad.ingest(voicedFrame(amplitude: 0.3)) } // in speech
        vad.reset()
        // Back to silence: one silence frame must not emit an offset, and onset
        // requires a fresh three-frame run.
        XCTAssertNil(vad.ingest(silenceFrame()))
        XCTAssertNil(vad.ingest(voicedFrame(amplitude: 0.3)))
        XCTAssertNil(vad.ingest(voicedFrame(amplitude: 0.3)))
        XCTAssertEqual(vad.ingest(voicedFrame(amplitude: 0.3)), .speechStart)
    }
}

// MARK: - Controller barge-in state machine

@MainActor
final class VoiceBargeInTests: XCTestCase {

    private var loudFrame: AudioFrame { AudioFrame(samples: [0.9, -0.9, 0.9, -0.9], sampleRate: 48_000) }
    private var echoFrame: AudioFrame { AudioFrame(samples: [0.9, -0.9, 0.9, -0.9], sampleRate: 48_000, isEcho: true) }

    private func makeController(
        enabled: Bool,
        frames: MockAudioFrameStream,
        synth: MockSpeechSynthesizer
    ) -> VoiceConversationController {
        VoiceConversationController(
            transcriber: StubTranscriber(),
            synthesizer: synth,
            voiceActivityDetector: RMSThresholdDetector(),
            bargeInListener: frames,
            isBargeInEnabled: enabled
        )
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, iterations: Int = 100) async {
        var count = 0
        while !condition(), count < iterations {
            await Task.yield()
            count += 1
        }
    }

    func test_monitorArmedDuringPlayback_andStoppedOnStop() async {
        let frames = MockAudioFrameStream()
        let synth = MockSpeechSynthesizer(); synth.shouldSuspend = true
        let controller = makeController(enabled: true, frames: frames, synth: synth)

        controller.enqueueReadback(of: "A reply")
        await Task.yield()
        XCTAssertTrue(controller.isSpeaking)
        XCTAssertTrue(frames.isCapturing, "barge-in monitor should arm when playback starts")
        XCTAssertEqual(frames.startCount, 1)

        controller.stopSpeaking()
        XCTAssertFalse(frames.isCapturing, "monitor should stop when playback stops")
        XCTAssertEqual(frames.stopCount, 1)
    }

    func test_disabledByDefault_neverArmsAndDoesNotInterrupt() async {
        let frames = MockAudioFrameStream()
        let synth = MockSpeechSynthesizer(); synth.shouldSuspend = true
        let controller = makeController(enabled: false, frames: frames, synth: synth)

        controller.enqueueReadback(of: "A reply")
        await Task.yield()
        XCTAssertTrue(controller.isSpeaking)
        XCTAssertFalse(frames.isCapturing, "monitor must not arm when barge-in is disabled")

        frames.push(loudFrame) // no-op: onFrame was never installed
        await Task.yield()
        XCTAssertTrue(controller.isSpeaking, "disabled barge-in must not interrupt playback")
    }

    func test_userSpeechWhileSpeaking_interruptsPlaybackAndHandsOffToRecording() async {
        let frames = MockAudioFrameStream()
        let synth = MockSpeechSynthesizer(); synth.shouldSuspend = true
        let controller = makeController(enabled: true, frames: frames, synth: synth)

        controller.enqueueReadback(of: "A long assistant reply the user talks over")
        await Task.yield()
        XCTAssertTrue(controller.isSpeaking)
        XCTAssertTrue(frames.isCapturing)

        frames.push(loudFrame) // user starts talking
        // Playback teardown is synchronous with the frame; recording is async.
        XCTAssertGreaterThanOrEqual(synth.stopCalls, 1, "playback should be interrupted")
        XCTAssertFalse(controller.isSpeaking)
        XCTAssertFalse(frames.isCapturing, "monitor should stop once barge-in fires")

        await waitUntil(controller.captureState == .recording)
        XCTAssertEqual(controller.captureState, .recording, "barge-in should hand off to recording")
    }

    func test_echoFramesDoNotSelfInterrupt_butRealSpeechStillDoes() async {
        let frames = MockAudioFrameStream()
        let synth = MockSpeechSynthesizer(); synth.shouldSuspend = true
        let controller = makeController(enabled: true, frames: frames, synth: synth)

        controller.enqueueReadback(of: "The assistant's own voice must not barge in")
        await Task.yield()
        XCTAssertTrue(frames.isCapturing)

        // The assistant's own output looping back (echo) must never fire barge-in,
        // even though it is loud enough for the detector.
        for _ in 0..<5 { frames.push(echoFrame) }
        await Task.yield()
        XCTAssertTrue(controller.isSpeaking, "echo must not self-interrupt")
        XCTAssertTrue(frames.isCapturing, "monitor should still be listening after echo")

        // A genuine (non-echo) loud frame with identical energy DOES interrupt —
        // proving the guard keys on `isEcho`, not on energy.
        frames.push(loudFrame)
        await waitUntil(controller.captureState == .recording)
        XCTAssertEqual(controller.captureState, .recording)
    }
}

// MARK: - Test doubles

/// Fires `.speechStart` for any sufficiently loud frame — decouples the
/// controller state-machine tests from the energy detector's tuning.
@MainActor
private final class RMSThresholdDetector: VoiceActivityDetector {
    private(set) var resetCount = 0
    func ingest(_ frame: AudioFrame) -> VoiceActivity? {
        frame.rootMeanSquare > 0.5 ? .speechStart : nil
    }
    func reset() { resetCount += 1 }
}

@MainActor
private final class MockAudioFrameStream: AudioFrameStream {
    private(set) var isCapturing = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?
    private var onFrame: (@MainActor (AudioFrame) -> Void)?

    func startCapturing(onFrame: @escaping @MainActor (AudioFrame) -> Void) throws {
        if let startError { throw startError }
        startCount += 1
        isCapturing = true
        self.onFrame = onFrame
    }

    func stopCapturing() {
        if isCapturing { stopCount += 1 }
        isCapturing = false
        onFrame = nil
    }

    /// Deliver a frame as if captured from the microphone.
    func push(_ frame: AudioFrame) { onFrame?(frame) }
}

@MainActor
private final class StubTranscriber: SpeechTranscribing {
    var authorizationStatus: VoiceAuthorizationStatus = .authorized
    func requestAuthorization() async -> VoiceAuthorizationStatus { authorizationStatus }
    func startTranscribing(onUpdate: @escaping @MainActor (SpeechTranscriptionUpdate) -> Void) async throws {}
    func stopTranscribing() async throws -> String? { nil }
    func cancelTranscribing() {}
}
