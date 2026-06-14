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

    /// Replace-mode regression: after a `stopSpeaking()` zeroes the counter, the
    /// cancelled predecessor's task resumes *after* a fresh enqueue restarts
    /// playback. Its teardown must not decrement the new generation's counter
    /// and falsely clear `isSpeaking` while the new utterance is still speaking.
    func test_stalePredecessorTaskDoesNotClearIsSpeakingForNewUtterance() async {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.shouldSuspend = true
        let controller = VoiceConversationController(
            transcriber: MockSpeechTranscriber(),
            synthesizer: synthesizer
        )

        // Start an utterance and stop it — but the mock holds the continuation
        // so the predecessor task hasn't run its teardown yet.
        controller.enqueueReadback(of: "First")
        await Task.yield()
        XCTAssertTrue(controller.isSpeaking)

        controller.stopSpeaking()              // bumps generation, zeroes counter
        XCTAssertFalse(controller.isSpeaking)

        // Start a new utterance in the new generation BEFORE the predecessor's
        // cancelled continuation resolves.
        controller.enqueueReadback(of: "Second")
        await Task.yield()
        XCTAssertTrue(controller.isSpeaking)

        // Now let the predecessor (generation N-1) resume from cancellation.
        // Without the generation guard it would decrement the new generation's
        // counter to 0 and clear `isSpeaking`.
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(controller.isSpeaking, "stale predecessor must not clear the new utterance's speaking state")

        synthesizer.finishCurrent()
        await Task.yield()
        XCTAssertFalse(controller.isSpeaking)
    }

    /// Enqueue-mode: two queued utterances keep `isSpeaking` true until both
    /// finish; finishing only the first must not prematurely clear it.
    func test_enqueueKeepsSpeakingUntilAllUtterancesFinish() async {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.shouldSuspend = true
        let controller = VoiceConversationController(
            transcriber: MockSpeechTranscriber(),
            synthesizer: synthesizer
        )

        controller.enqueueReadback(of: "One")
        await Task.yield()
        controller.enqueueReadback(of: "Two")
        await Task.yield()

        XCTAssertEqual(synthesizer.spokenEnqueueFlags, [true, true])
        XCTAssertTrue(controller.isSpeaking)

        synthesizer.finishCurrent()
        await Task.yield()
        XCTAssertTrue(controller.isSpeaking, "still speaking with one utterance left in queue")

        synthesizer.finishCurrent()
        await Task.yield()
        XCTAssertFalse(controller.isSpeaking)
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
        // Faithful to `AppleSpeechSynthesizer`: replace mode cancels whatever is
        // currently queued before enqueuing the new utterance, which resumes the
        // prior continuation(s) with `CancellationError`.
        if !enqueue {
            let prior = continuations
            continuations.removeAll()
            for continuation in prior {
                continuation.resume(throwing: CancellationError())
            }
        }

        spokenTexts.append(text)
        spokenOptions.append(options)
        spokenEnqueueFlags.append(enqueue)

        if shouldSuspend {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuations.append(continuation)
            }
        }
    }

    /// Resumes the most-recently suspended utterance successfully (simulates
    /// `didFinish` for the current utterance).
    func finishCurrent() {
        guard !continuations.isEmpty else { return }
        let continuation = continuations.removeLast()
        continuation.resume()
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
