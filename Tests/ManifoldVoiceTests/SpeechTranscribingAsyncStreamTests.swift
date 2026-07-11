import XCTest
@testable import ManifoldVoice

/// Covers `SpeechTranscribing.transcriptionUpdates()` (#2157, plan 1.6): the
/// additive `AsyncThrowingStream` adapter over the callback-based
/// `startTranscribing(onUpdate:)` API. The callback API itself is exercised
/// elsewhere (`VoiceConversationControllerTests`); these tests are scoped to
/// the new stream adapter's own contract — yielding, finishing on `isFinal`,
/// propagating a thrown setup error, and cancelling the underlying
/// transcriber when the consumer walks away.
@MainActor
final class SpeechTranscribingAsyncStreamTests: XCTestCase {

    func test_transcriptionUpdates_yieldsEachUpdateInOrder() async throws {
        let transcriber = StreamMockSpeechTranscriber()
        let stream = transcriber.transcriptionUpdates()

        var received: [SpeechTranscriptionUpdate] = []
        let consumer = Task { @MainActor in
            for try await update in stream {
                received.append(update)
            }
        }

        // Wait until `startTranscribing` has actually registered its callback
        // before emitting — otherwise updates race the stream's setup.
        await transcriber.waitUntilStarted()

        await transcriber.emit(text: "Hello", isFinal: false)
        await transcriber.emit(text: "Hello Manifold", isFinal: true)

        try await consumer.value

        XCTAssertEqual(received.map(\.text), ["Hello", "Hello Manifold"])
        XCTAssertEqual(received.map(\.isFinal), [false, true])
    }

    func test_transcriptionUpdates_finishesStreamOnIsFinal() async throws {
        let transcriber = StreamMockSpeechTranscriber()
        let stream = transcriber.transcriptionUpdates()

        let consumer = Task { @MainActor () -> [SpeechTranscriptionUpdate] in
            var updates: [SpeechTranscriptionUpdate] = []
            for try await update in stream {
                updates.append(update)
            }
            return updates
        }

        await transcriber.waitUntilStarted()
        await transcriber.emit(text: "done", isFinal: true)

        // The consumer's `for try await` loop must exit on its own (the
        // stream finishes) rather than needing external cancellation — proves
        // `continuation.finish()` fires on the `isFinal` branch.
        let updates = try await consumer.value
        XCTAssertEqual(updates, [SpeechTranscriptionUpdate(text: "done", isFinal: true)])
    }

    func test_transcriptionUpdates_propagatesStartTranscribingError() async throws {
        struct SetupFailure: Error, Equatable {}

        let transcriber = StreamMockSpeechTranscriber()
        transcriber.startError = SetupFailure()
        let stream = transcriber.transcriptionUpdates()

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected the stream to throw the setup error")
        } catch {
            XCTAssertTrue(error is SetupFailure)
        }
    }

    func test_transcriptionUpdates_cancelsUnderlyingTranscriberWhenConsumerStops() async throws {
        let transcriber = StreamMockSpeechTranscriber()
        let stream = transcriber.transcriptionUpdates()

        let consumer = Task { @MainActor in
            for try await _ in stream {
                // Consume until the surrounding task is cancelled below.
            }
        }

        await transcriber.waitUntilStarted()
        await transcriber.emit(text: "partial", isFinal: false)

        // Cancelling the consuming task is what `AsyncThrowingStream`
        // documents as triggering `onTermination(.cancelled)` — a plain
        // `break` does not, since the stream/continuation stays alive as
        // long as `stream` is in scope. This must propagate into a
        // `cancelTranscribing()` call on the receiver — proves the wrapper
        // doesn't leak the underlying transcription session.
        consumer.cancel()
        _ = try? await consumer.value

        try await waitUntil(timeout: .seconds(2)) { transcriber.cancelCalls > 0 }
        XCTAssertGreaterThan(transcriber.cancelCalls, 0)
    }

    /// Sabotage-style guard: a `waitUntil` helper that never observes the
    /// condition times out rather than hanging the suite.
    private func waitUntil(
        timeout: Duration,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("condition not met before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A `SpeechTranscribing` mock dedicated to the `transcriptionUpdates()`
/// adapter tests. Kept separate from `VoiceConversationControllerTests`'s
/// private `MockSpeechTranscriber` (file-private there) rather than sharing.
@MainActor
private final class StreamMockSpeechTranscriber: SpeechTranscribing {
    var authorizationStatus: VoiceAuthorizationStatus = .authorized
    var startError: Error?
    var cancelCalls = 0

    private var onUpdate: (@MainActor (SpeechTranscriptionUpdate) -> Void)?
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var isStarted = false

    func requestAuthorization() async -> VoiceAuthorizationStatus {
        authorizationStatus
    }

    func startTranscribing(
        onUpdate: @escaping @MainActor (SpeechTranscriptionUpdate) -> Void
    ) async throws {
        if let startError {
            throw startError
        }
        self.onUpdate = onUpdate
        isStarted = true
        let pending = startedContinuations
        startedContinuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func stopTranscribing() async throws -> String? {
        nil
    }

    func cancelTranscribing() {
        cancelCalls += 1
    }

    /// Suspends until `startTranscribing` has registered its callback, so
    /// tests can `emit` without racing the stream's setup `Task`.
    func waitUntilStarted() async {
        if isStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func emit(text: String, isFinal: Bool) async {
        onUpdate?(SpeechTranscriptionUpdate(text: text, isFinal: isFinal))
    }
}
