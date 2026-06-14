import XCTest
@testable import ManifoldVoice

@MainActor
final class VoiceConversationControllerTests: XCTestCase {

    func test_startAndStopRecordingPublishesTranscript() async {
        let transcriber = MockSpeechTranscriber()
        transcriber.stopResult = "Hello Manifold"
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer()
        )

        await controller.startRecording()
        XCTAssertEqual(controller.captureState, .recording)

        await transcriber.emit(text: "Hello Manifold", isFinal: false)
        XCTAssertEqual(controller.liveTranscript, "Hello Manifold")

        let transcript = await controller.stopRecording()
        XCTAssertEqual(transcript, "Hello Manifold")
        XCTAssertEqual(controller.lastCommittedTranscript, "Hello Manifold")
        XCTAssertEqual(controller.captureState, .idle)
    }

    func test_startRecordingSurfacesPermissionFailure() async {
        let transcriber = MockSpeechTranscriber()
        transcriber.authorizationStatus = .microphoneDenied
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer()
        )

        await controller.startRecording()

        XCTAssertEqual(controller.captureState, .failed("Microphone access is required for voice input."))
        XCTAssertEqual(controller.statusText, "Microphone access is required for voice input.")
    }

    func test_togglePlaybackStartsAndStopsSpeech() async {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.shouldSuspend = true
        let controller = VoiceConversationController(
            transcriber: MockSpeechTranscriber(),
            synthesizer: synthesizer
        )

        controller.togglePlayback(for: "Read me")
        await Task.yield()

        XCTAssertTrue(controller.isSpeaking)
        XCTAssertEqual(synthesizer.spokenTexts, ["Read me"])

        controller.stopSpeaking()

        XCTAssertFalse(controller.isSpeaking)
        XCTAssertEqual(synthesizer.stopCalls, 1)
    }

    func test_cancelRecordingResetsTranscriptState() async {
        let transcriber = MockSpeechTranscriber()
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer()
        )

        await controller.startRecording()
        await transcriber.emit(text: "Partial", isFinal: false)
        controller.cancelRecording()

        XCTAssertEqual(controller.captureState, .idle)
        XCTAssertEqual(controller.liveTranscript, "")
        XCTAssertEqual(transcriber.cancelCalls, 1)
    }

    func test_cancelRecordingClearsWakeWordToast() async {
        let transcriber = MockSpeechTranscriber()
        let sleeper = ControlledToastSleeper()
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer(),
            wakeWordDetector: AppleWakeWordDetector(wakeWords: ["hey base chat"]),
            wakeWordToastDuration: .seconds(1),
            toastSleeper: { duration in try await sleeper.sleep(for: duration) }
        )

        await controller.startRecording()
        await transcriber.emit(text: "hey base chat draft this reply", isFinal: false)
        await Task.yield()

        XCTAssertNotNil(controller.recentWakeWordDetection)

        controller.cancelRecording()

        XCTAssertNil(controller.recentWakeWordDetection)
    }

    func test_stopRecordingClearsWakeWordToast() async {
        let transcriber = MockSpeechTranscriber()
        transcriber.stopResult = "hey base chat draft this reply"
        let sleeper = ControlledToastSleeper()
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer(),
            wakeWordDetector: AppleWakeWordDetector(wakeWords: ["hey base chat"]),
            wakeWordToastDuration: .seconds(1),
            toastSleeper: { duration in try await sleeper.sleep(for: duration) }
        )

        await controller.startRecording()
        await transcriber.emit(text: "hey base chat draft this reply", isFinal: false)
        await Task.yield()

        XCTAssertNotNil(controller.recentWakeWordDetection)

        _ = await controller.stopRecording()

        XCTAssertNil(controller.recentWakeWordDetection)
    }

    func test_wakeWordDetectionAppearsAndDismisses() async {
        let transcriber = MockSpeechTranscriber()
        let sleeper = ControlledToastSleeper()
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer(),
            wakeWordDetector: AppleWakeWordDetector(wakeWords: ["hey base chat"]),
            wakeWordToastDuration: .seconds(1),
            toastSleeper: { duration in try await sleeper.sleep(for: duration) }
        )

        await controller.startRecording()
        await transcriber.emit(text: "hey base chat summarize this thread", isFinal: false)
        await Task.yield()

        XCTAssertEqual(
            controller.recentWakeWordDetection,
            WakeWordDetection(
                phrase: "hey base chat",
                transcript: "hey base chat summarize this thread"
            )
        )
        XCTAssertEqual(sleeper.recordedDurations, [.seconds(1)])

        sleeper.resume()
        for _ in 0..<20 where controller.recentWakeWordDetection != nil {
            await Task.yield()
        }

        XCTAssertNil(controller.recentWakeWordDetection)
    }
}

@MainActor
private final class MockSpeechTranscriber: SpeechTranscribing {
    var authorizationStatus: VoiceAuthorizationStatus = .authorized
    var stopResult: String?
    var stopError: Error?
    var cancelCalls = 0
    private var onUpdate: (@MainActor (SpeechTranscriptionUpdate) -> Void)?

    func requestAuthorization() async -> VoiceAuthorizationStatus {
        authorizationStatus
    }

    func startTranscribing(
        onUpdate: @escaping @MainActor (SpeechTranscriptionUpdate) -> Void
    ) async throws {
        self.onUpdate = onUpdate
    }

    func stopTranscribing() async throws -> String? {
        if let stopError { throw stopError }
        return stopResult
    }

    func cancelTranscribing() {
        cancelCalls += 1
    }

    func emit(text: String, isFinal: Bool) async {
        onUpdate?(SpeechTranscriptionUpdate(text: text, isFinal: isFinal))
    }
}

@MainActor
final class MockSpeechSynthesizer: SpeechSynthesizing {
    var spokenTexts: [String] = []
    var spokenOptions: [SpeechOptions] = []
    var spokenEnqueueFlags: [Bool] = []
    var stopCalls = 0
    var shouldSuspend = false
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func speak(_ text: String, options: SpeechOptions, enqueue: Bool) async throws {
        spokenTexts.append(text)
        spokenOptions.append(options)
        spokenEnqueueFlags.append(enqueue)

        if shouldSuspend {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuations.append(continuation)
            }
        }
    }

    func stopSpeaking() {
        stopCalls += 1
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
    }
}

@MainActor
private final class ControlledToastSleeper {
    private(set) var recordedDurations: [Duration] = []
    private var continuation: CheckedContinuation<Void, Error>?

    func sleep(for duration: Duration) async throws {
        recordedDurations.append(duration)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
