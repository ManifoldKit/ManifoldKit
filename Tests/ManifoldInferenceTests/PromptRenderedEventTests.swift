import XCTest
import Foundation
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for the `captureRenderedPrompt` opt-in and the resulting
/// `.promptRendered(text:)` event.
///
/// Exercises the opt-in/opt-out gate in `GenerationQueue.dispatchToBackend`
/// without hitting a real backend. Uses `XCTestCase` per #681 (Swift Testing
/// mixed with XCTest triggers libmalloc SIGABRT in the same process).
@MainActor
final class PromptRenderedEventTests: XCTestCase {

    // MARK: - Fixture

    private var backend: MockInferenceBackend!
    private var provider: FakePromptRenderedTestProvider!
    private var queue: GenerationQueue!

    override func setUp() async throws {
        try await super.setUp()
        backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["A", "B"]
        provider = FakePromptRenderedTestProvider(backend: backend)
        queue = GenerationQueue()
        provider.bind(to: queue)
    }

    override func tearDown() async throws {
        await queue?.stopGenerationAndWait()
        queue = nil
        provider = nil
        backend = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func collectEvents(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    private func generate(hints: GenerationRuntimeHints = GenerationRuntimeHints()) async throws -> [GenerationEvent] {
        let (_, stream) = try queue.enqueue(
            structuredMessages: [StructuredMessage(role: "user", content: "hello")],
            systemPrompt: nil,
            config: GenerationConfig(),
            hints: hints
        )
        return try await collectEvents(stream)
    }

    // MARK: - Opt-in emits event

    func test_captureRenderedPrompt_true_emitsPromptRenderedAsFirstEvent() async throws {
        let events = try await generate(hints: GenerationRuntimeHints(captureRenderedPrompt: true))

        // The very first event must be .promptRendered.
        guard case .promptRendered = events.first else {
            XCTFail("Expected .promptRendered as first event, got: \(events.first as Any)")
            return
        }
    }

    func test_captureRenderedPrompt_true_promptRenderedTextMatchesUserMessage() async throws {
        let events = try await generate(hints: GenerationRuntimeHints(captureRenderedPrompt: true))

        guard case .promptRendered(let text) = events.first else {
            XCTFail("Expected .promptRendered as first event")
            return
        }
        // Non-template backend passes the last user message as `prompt:`,
        // so the rendered text should contain the user content.
        XCTAssertFalse(text.isEmpty, "promptRendered text must not be empty")
        XCTAssertTrue(text.contains("hello"), "promptRendered text must contain the user message")
    }

    func test_captureRenderedPrompt_true_tokenEventFollowsPromptRendered() async throws {
        let events = try await generate(hints: GenerationRuntimeHints(captureRenderedPrompt: true))

        let hasPromptRendered = events.contains { if case .promptRendered = $0 { return true } else { return false } }
        let hasToken = events.contains { if case .token = $0 { return true } else { return false } }
        XCTAssertTrue(hasPromptRendered, "stream must include .promptRendered when opt-in is true")
        XCTAssertTrue(hasToken, "stream must still include token events after .promptRendered")

        // Verify ordering: .promptRendered must precede any .token.
        let promptRenderedIdx = events.firstIndex { if case .promptRendered = $0 { return true } else { return false } }
        let firstTokenIdx = events.firstIndex { if case .token = $0 { return true } else { return false } }
        if let prIdx = promptRenderedIdx, let tkIdx = firstTokenIdx {
            XCTAssertLessThan(prIdx, tkIdx, ".promptRendered must appear before the first .token")
        }
    }

    // MARK: - Opt-out emits no event

    func test_captureRenderedPrompt_false_noPromptRenderedEvent() async throws {
        // Default hints have captureRenderedPrompt == false.
        XCTAssertFalse(GenerationRuntimeHints().captureRenderedPrompt, "captureRenderedPrompt must default to false")

        let events = try await generate()

        let hasPromptRendered = events.contains { if case .promptRendered = $0 { return true } else { return false } }
        XCTAssertFalse(hasPromptRendered, "stream must NOT include .promptRendered when opt-in is false (default)")
    }

    func test_captureRenderedPrompt_explicitFalse_noPromptRenderedEvent() async throws {
        let events = try await generate(hints: GenerationRuntimeHints(captureRenderedPrompt: false))

        let hasPromptRendered = events.contains { if case .promptRendered = $0 { return true } else { return false } }
        XCTAssertFalse(hasPromptRendered, "stream must NOT include .promptRendered when explicitly set to false")
    }

    // MARK: - Exactly once

    func test_captureRenderedPrompt_true_emitsExactlyOnePromptRenderedEvent() async throws {
        let events = try await generate(hints: GenerationRuntimeHints(captureRenderedPrompt: true))

        let count = events.filter { if case .promptRendered = $0 { return true } else { return false } }.count
        XCTAssertEqual(count, 1, ".promptRendered must be emitted exactly once per turn")
    }
}

// MARK: - Test fixture

/// Minimal context provider wiring a `MockInferenceBackend` into a
/// `GenerationQueue` for `PromptRenderedEventTests`. Uses
/// `requiresPromptTemplate: false` (the default) so `assembledPrompt` is the
/// last user-message content — a simple, predictable string to assert on.
@MainActor
private final class FakePromptRenderedTestProvider {
    let backend: MockInferenceBackend

    init(backend: MockInferenceBackend) {
        self.backend = backend
    }

    func bind(to queue: GenerationQueue) {
        queue.bindContext(
            currentBackend: { [weak self] in self?.backend },
            isBackendLoaded: { [weak self] in self?.backend.isModelLoaded ?? false },
            selectedPromptTemplate: { .chatML }
        )
    }
}
