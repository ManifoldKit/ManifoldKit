import XCTest
@testable import ManifoldVoice

/// Polls `condition` until it becomes true or `timeout` elapses, yielding
/// between checks so a suspended continuation's task gets scheduling hops to
/// resume and run its teardown. A single `Task.yield()` only guarantees one
/// hop — not enough for the controller's async continuation to reliably
/// settle under `swift test --parallel` on a loaded CI runner, which is what
/// made `test_enqueueKeepsSpeakingUntilAllUtterancesFinish` flaky (#2246).
/// Fails loudly on timeout rather than silently passing on a lucky guess.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now >= deadline {
            XCTFail("condition did not become true within \(timeout)", file: file, line: line)
            return
        }
        await Task.yield()
    }
}

/// For settle points that assert the *absence* of a state change (so there is
/// no positive condition to poll), gives queued continuations many scheduling
/// hops to resume and run to completion before the assertion. Far more
/// generous than the single yield that let #2246 through.
@MainActor
private func drainScheduler(hops: Int = 50) async {
    for _ in 0..<hops {
        await Task.yield()
    }
}

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

    /// The wake-word affordance was removed: it could only ever fire while a
    /// recording was already open (the detector was fed by the recording's
    /// transcription stream) and merely flashed a toast — it never started a
    /// recording, which is the whole point of a wake word. Honest behaviour is
    /// that a spoken "wake phrase" during recording is just ordinary transcript
    /// text and triggers no special state.
    func test_spokenWakePhraseDuringRecordingIsPlainTranscript() async {
        let transcriber = MockSpeechTranscriber()
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer()
        )

        await controller.startRecording()
        await transcriber.emit(text: "hey manifold draft this reply", isFinal: false)

        // Treated as plain dictated text — no hidden wake-word branch remains.
        XCTAssertEqual(controller.liveTranscript, "hey manifold draft this reply")
        XCTAssertEqual(controller.captureState, .recording)
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

    func test_deniedPermissionOffersOpenSettingsRecovery() async {
        let transcriber = MockSpeechTranscriber()
        transcriber.authorizationStatus = .denied
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer()
        )

        await controller.startRecording()

        XCTAssertEqual(controller.recoveryAffordance, .openSettings)
        XCTAssertEqual(controller.statusText, "Speech recognition permission is required for voice input.")
    }

    func test_notDeterminedIsNotDeniedAndRequestsAgain() async {
        let transcriber = MockSpeechTranscriber()
        transcriber.authorizationStatus = .notDetermined
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer()
        )

        await controller.startRecording()

        // notDetermined must map to a distinct, non-blaming "tap to allow" state
        // — never the denied affordance/message.
        XCTAssertEqual(controller.recoveryAffordance, .requestAgain)
        XCTAssertNotEqual(controller.recoveryAffordance, .openSettings)
        XCTAssertEqual(controller.statusText, "Tap to allow microphone and speech access for voice input.")
        XCTAssertNotEqual(
            controller.statusText,
            "Speech recognition permission is required for voice input.",
            "notDetermined must not be labelled as denied"
        )
    }

    func test_microphoneDeniedOffersOpenSettingsRecovery() async {
        let transcriber = MockSpeechTranscriber()
        transcriber.authorizationStatus = .microphoneDenied
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer()
        )

        await controller.startRecording()

        XCTAssertEqual(controller.recoveryAffordance, .openSettings)
    }

    func test_emptyTranscriptSurfacesDidntCatchThat() async {
        let transcriber = MockSpeechTranscriber()
        transcriber.stopResult = "   " // whitespace only → resolves to empty
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer()
        )

        await controller.startRecording()
        let transcript = await controller.stopRecording()

        XCTAssertNil(transcript)
        XCTAssertEqual(controller.captureState, .idle)
        // Not silent: a brief, non-blaming nudge with a retry affordance.
        XCTAssertEqual(controller.statusText, "Didn't catch that — tap to try again.")
        XCTAssertEqual(controller.recoveryAffordance, .retry)
    }

    func test_startRecordingClearsPriorRecoveryAffordance() async {
        let transcriber = MockSpeechTranscriber()
        transcriber.authorizationStatus = .denied
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer()
        )

        await controller.startRecording()
        XCTAssertEqual(controller.recoveryAffordance, .openSettings)

        // A subsequent successful authorization clears the stale affordance.
        transcriber.authorizationStatus = .authorized
        await controller.startRecording()
        XCTAssertNil(controller.recoveryAffordance)
        XCTAssertEqual(controller.captureState, .recording)
    }

    func test_togglePlaybackStartsAndStopsSpeech() async {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.shouldSuspend = true
        let controller = VoiceConversationController(
            transcriber: MockSpeechTranscriber(),
            synthesizer: synthesizer
        )

        controller.togglePlayback(for: "Read me")
        await waitUntil { synthesizer.spokenTexts == ["Read me"] }

        XCTAssertTrue(controller.isSpeaking)
        XCTAssertEqual(synthesizer.spokenTexts, ["Read me"])

        controller.stopSpeaking()

        XCTAssertFalse(controller.isSpeaking)
        XCTAssertEqual(synthesizer.stopCalls, 1)
    }

    /// #2128 inert-surface sweep, part B: `onSpeechProgress` installed through
    /// the controller must reach the underlying synthesizer's own
    /// `SpeechProgressReporting.onSpeechProgress` — proving the forwarding
    /// wire is live, not just a property that compiles.
    func test_onSpeechProgress_installedThroughControllerReachesSynthesizer() {
        let synthesizer = MockSpeechSynthesizer()
        let controller = VoiceConversationController(
            transcriber: MockSpeechTranscriber(),
            synthesizer: synthesizer
        )

        var received: SpeechProgress?
        controller.onSpeechProgress = { progress in received = progress }

        // The handler must actually be installed on the concrete synthesizer,
        // not just stored on the controller.
        XCTAssertNotNil(synthesizer.onSpeechProgress)

        let text = "read along"
        let range = text.range(of: "along")!
        let progress = SpeechProgress(utteranceID: UUID(), text: text, spokenRange: range)
        synthesizer.emitProgress(progress)

        XCTAssertEqual(received?.spokenText, "along")
        XCTAssertEqual(controller.onSpeechProgress != nil, true)
    }

    /// A synthesizer that does not conform to `SpeechProgressReporting`
    /// degrades to a no-op read/write rather than crashing — the documented
    /// "engines without range reporting simply don't conform" contract.
    func test_onSpeechProgress_noOpsForNonConformingSynthesizer() {
        let synthesizer = NonReportingSpeechSynthesizer()
        let controller = VoiceConversationController(
            transcriber: MockSpeechTranscriber(),
            synthesizer: synthesizer
        )

        XCTAssertNil(controller.onSpeechProgress)
        controller.onSpeechProgress = { _ in XCTFail("should never be called") }
        XCTAssertNil(controller.onSpeechProgress)
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
        await waitUntil { synthesizer.spokenTexts == ["First"] }
        XCTAssertTrue(controller.isSpeaking)

        controller.stopSpeaking()              // bumps generation, zeroes counter
        XCTAssertFalse(controller.isSpeaking)

        // Start a new utterance in the new generation BEFORE the predecessor's
        // cancelled continuation resolves.
        controller.enqueueReadback(of: "Second")
        await waitUntil { synthesizer.spokenTexts == ["First", "Second"] }
        XCTAssertTrue(controller.isSpeaking)

        // Now let the predecessor (generation N-1) resume from cancellation.
        // Without the generation guard it would decrement the new generation's
        // counter to 0 and clear `isSpeaking`. There's no positive condition to
        // poll for here — we're asserting an *absence* of change — so give the
        // cancelled task many scheduling hops to actually reach its guard check
        // instead of guessing a fixed yield count (the guess is what let #2246
        // through under a loaded `swift test --parallel` runner).
        await drainScheduler()
        XCTAssertTrue(controller.isSpeaking, "stale predecessor must not clear the new utterance's speaking state")

        synthesizer.finishCurrent()
        await waitUntil { !controller.isSpeaking }
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
        await waitUntil { synthesizer.spokenEnqueueFlags.count == 1 }
        controller.enqueueReadback(of: "Two")
        await waitUntil { synthesizer.spokenEnqueueFlags.count == 2 }

        XCTAssertEqual(synthesizer.spokenEnqueueFlags, [true, true])
        XCTAssertTrue(controller.isSpeaking)

        synthesizer.finishCurrent()
        // "Still speaking" is already true before the resumed task's teardown
        // runs, so there's no positive condition to poll — drain the scheduler
        // generously instead of guessing a fixed yield count, so a regression
        // that clears `isSpeaking` too early is still caught (#2246).
        await drainScheduler()
        XCTAssertTrue(controller.isSpeaking, "still speaking with one utterance left in queue")

        synthesizer.finishCurrent()
        await waitUntil { !controller.isSpeaking }
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
final class MockSpeechSynthesizer: SpeechSynthesizing, SpeechProgressReporting {
    var spokenTexts: [String] = []
    var spokenOptions: [SpeechOptions] = []
    var spokenEnqueueFlags: [Bool] = []
    var stopCalls = 0
    var shouldSuspend = false
    private var continuations: [CheckedContinuation<Void, Error>] = []

    /// ``SpeechProgressReporting`` conformance — lets tests prove a handler
    /// installed through ``VoiceConversationController/onSpeechProgress``
    /// reaches the concrete synthesizer, mirroring `AppleSpeechSynthesizer`.
    var onSpeechProgress: (@MainActor (SpeechProgress) -> Void)?

    /// Test-only helper simulating a spoken-range delegate callback.
    func emitProgress(_ progress: SpeechProgress) {
        onSpeechProgress?(progress)
    }

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

/// A minimal `SpeechSynthesizing` conformer that deliberately does NOT
/// conform to `SpeechProgressReporting`, exercising
/// ``VoiceConversationController/onSpeechProgress``'s no-op degrade path.
@MainActor
final class NonReportingSpeechSynthesizer: SpeechSynthesizing {
    func speak(_ text: String, options: SpeechOptions, enqueue: Bool) async throws {}
    func stopSpeaking() {}
}
