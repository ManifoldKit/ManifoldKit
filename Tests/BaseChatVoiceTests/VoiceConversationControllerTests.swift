import XCTest
@testable import BaseChatVoice

@MainActor
final class VoiceConversationControllerTests: XCTestCase {

    func test_startAndStopRecordingPublishesTranscript() async {
        let transcriber = MockSpeechTranscriber()
        transcriber.stopResult = "Hello BaseChat"
        let controller = VoiceConversationController(
            transcriber: transcriber,
            synthesizer: MockSpeechSynthesizer()
        )

        await controller.startRecording()
        XCTAssertEqual(controller.captureState, .recording)

        await transcriber.emit(text: "Hello BaseChat", isFinal: false)
        XCTAssertEqual(controller.liveTranscript, "Hello BaseChat")

        let transcript = await controller.stopRecording()
        XCTAssertEqual(transcript, "Hello BaseChat")
        XCTAssertEqual(controller.lastCommittedTranscript, "Hello BaseChat")
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
private final class MockSpeechSynthesizer: SpeechSynthesizing {
    var spokenTexts: [String] = []
    var stopCalls = 0
    var shouldSuspend = false
    private var continuation: CheckedContinuation<Void, Error>?

    func speak(_ text: String) async throws {
        spokenTexts.append(text)

        if shouldSuspend {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
            }
        }
    }

    func stopSpeaking() {
        stopCalls += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
