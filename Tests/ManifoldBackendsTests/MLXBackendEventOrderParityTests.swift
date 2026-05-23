#if MLX
import XCTest
import MLXLMCommon
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldMLX

/// Pins the **event ordering** emitted by `MLXBackend.generate(...)` against
/// a frozen expected sequence.
///
/// Phase 2.5/β (PR #1271) moved generation out of `MLXBackend` into
/// `MLXGenerationDriver`. The migration kept behavioural-parity tests
/// asserting that *individual* events still flow (tokens, thinking,
/// kvCacheReuse). But the QA review flagged that no test pinned the
/// **full sequence** — in particular the ordering between `.kvCacheReuse`
/// and the first `.token`. A future refactor that re-orders the driver's
/// initial yields wouldn't trip any existing assertion.
///
/// These tests are the cheap analog of #1269's
/// `OpenAIStreamEventExtractor` 5 inline-parity tests: drive a scripted
/// `MockMLXModelContainer` through `MLXBackend.generate(...)` and assert
/// the resulting event sequence matches a literal expected list. Once
/// Phase 4 contract tests land they become redundant — for now they lock
/// down ordering against future delegation drift.
///
/// All three scenarios run on the mock container, no Metal / Apple
/// Silicon required.
final class MLXBackendEventOrderParityTests: XCTestCase {

    // MARK: - Helpers

    /// Drains a stream into an ordered event list and a parallel kind list
    /// so assertions can compare on **case identity** without caring about
    /// associated values that may legitimately vary (e.g. the exact reused
    /// token count when the mock changes).
    private func collectEvents(
        from stream: GenerationStream
    ) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    /// String tag for an event used in the assertions below. Stable across
    /// associated-value churn so the parity test stays pinned to the
    /// **shape** of the stream rather than the exact payloads (those have
    /// dedicated coverage elsewhere).
    private func tag(_ event: GenerationEvent) -> String {
        switch event {
        case .token: return "token"
        case .thinkingToken: return "thinkingToken"
        case .thinkingComplete: return "thinkingComplete"
        case .thinkingSignature: return "thinkingSignature"
        case .kvCacheReuse: return "kvCacheReuse"
        case .toolCallStart: return "toolCallStart"
        case .toolCallArgumentsDelta: return "toolCallArgumentsDelta"
        case .toolCall: return "toolCall"
        case .toolResult: return "toolResult"
        case .toolLoopLimitReached: return "toolLoopLimitReached"
        case .toolDispatchStarted: return "toolDispatchStarted"
        case .toolDispatchCompleted: return "toolDispatchCompleted"
        case .usage: return "usage"
        case .prefillProgress: return "prefillProgress"
        case .diagnosticThrottle: return "diagnosticThrottle"
        case .handoffRequested: return "handoffRequested"
        }
    }

    // MARK: - 1. Simple completion: tokens only, no kvCacheReuse

    /// Cold-start generation must yield only `.token` events in order, with
    /// no `.kvCacheReuse` (no prior snapshot to reuse from).
    func test_simpleCompletion_emitsTokensInOrder_withoutKVCacheReuse() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["Hello", " ", "world"]

        let backend = MLXBackend()
        backend._inject(mock)

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        let events = try await collectEvents(from: stream)
        let tags = events.map(tag)

        XCTAssertEqual(
            tags,
            ["token", "token", "token"],
            "Cold-start completion must emit exactly three .token events in order, no .kvCacheReuse"
        )

        // Pin the payload order too — token values must match the mock's
        // yield order one-for-one.
        let tokenTexts = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        XCTAssertEqual(tokenTexts, ["Hello", " ", "world"])
    }

    // MARK: - 2. KV-cache reuse: .kvCacheReuse fires BEFORE any .token

    /// On a second turn with a matching prompt prefix, `.kvCacheReuse` must
    /// precede every `.token`. Re-ordering the driver's initial yields
    /// would surface here.
    func test_kvCacheReuse_precedesFirstToken() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]
        mock.preparedTokenBatches = [
            [11, 12, 13, 14],
            [11, 12, 13, 14, 15],
        ]

        let backend = MLXBackend(enableKVCacheReuse: true)
        backend._inject(mock)

        // First turn primes the snapshot — discard events.
        _ = try await collectEvents(from: try backend.generate(
            prompt: "first",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        // Wait for the async snapshot-capture task to finish writing back
        // into _promptCacheState. Without this poll the second turn races
        // the snapshot write and `existingSnapshot` reads as nil, suppressing
        // the .kvCacheReuse event entirely. The existing
        // test_generate_reusesPromptCachePrefixOnMatchingTurn test in
        // MLXBackendGenerationTests hits the same race when run in
        // isolation; staging the poll here keeps this suite reliable
        // regardless of `--filter` ordering.
        let snapshotReady = expectation(description: "prompt cache snapshot ready")
        Task {
            let deadline = ContinuousClock.now + .seconds(2)
            while !backend._isPromptCacheSnapshotReadyForTesting(),
                  ContinuousClock.now < deadline {
                await Task.yield()
            }
            snapshotReady.fulfill()
        }
        await fulfillment(of: [snapshotReady], timeout: 3)
        XCTAssertTrue(
            backend._isPromptCacheSnapshotReadyForTesting(),
            "Prompt-cache snapshot must be persisted before the second turn — required for .kvCacheReuse to fire"
        )

        // Second turn: shared prefix triggers .kvCacheReuse before the
        // single token.
        let secondStream = try backend.generate(
            prompt: "second",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        let events = try await collectEvents(from: secondStream)
        let tags = events.map(tag)

        // Find the indices of the kvCacheReuse and first token events. Pin
        // the ordering between them without over-asserting on incidental
        // events (e.g. .prefillProgress) the driver may emit between.
        guard let reuseIdx = tags.firstIndex(of: "kvCacheReuse") else {
            XCTFail("KV-cache-reuse turn must include .kvCacheReuse; got: \(tags)")
            return
        }
        guard let firstTokenIdx = tags.firstIndex(of: "token") else {
            XCTFail("KV-cache-reuse turn must yield at least one .token; got: \(tags)")
            return
        }
        XCTAssertLessThan(
            reuseIdx, firstTokenIdx,
            ".kvCacheReuse must precede first .token (driver init order); got: \(tags)"
        )

        // Verify the .kvCacheReuse associated value: 4-token shared prefix.
        if case .kvCacheReuse(let reused) = events[reuseIdx] {
            XCTAssertEqual(reused, 4, "Shared prefix length")
        } else {
            XCTFail("Expected .kvCacheReuse case at index \(reuseIdx)")
        }
    }

    // MARK: - 3. Cancellation mid-stream: tokens emitted up to break point

    /// Cancelling the stream after the first token must surface exactly the
    /// events the consumer observed before breaking — no extra synthesised
    /// events from the driver. This pins the contract that mid-stream
    /// teardown doesn't inject phantom completion / usage events the
    /// consumer never asked for.
    func test_cancelMidStream_yieldsOnlyConsumedTokens() async throws {
        let mock = MockMLXModelContainer()
        // Use a generous yield list so the producer always has work
        // queued up at the cancel point.
        mock.tokensToYield = ["a", "b", "c", "d", "e"]

        let backend = MLXBackend()
        backend._inject(mock)

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var observed: [GenerationEvent] = []
        for try await event in stream.events {
            observed.append(event)
            if case .token = event, observed.count == 2 {
                break
            }
        }

        let tags = observed.map(tag)
        XCTAssertEqual(
            tags,
            ["token", "token"],
            "Mid-stream cancel must only surface the two consumed .token events — no phantom completion / .usage / .stopReason"
        )

        // Wait for the cancel to propagate so other tests aren't racing on
        // shared backend state. Matches the pattern in
        // MLXBackendGenerationTests.test_generate_cancellation.
        let expectation = expectation(description: "isGenerating clears after cancel")
        Task {
            let deadline = ContinuousClock.now + .seconds(2)
            while backend.isGenerating, ContinuousClock.now < deadline {
                await Task.yield()
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 3)
        XCTAssertFalse(backend.isGenerating)
    }
}
#endif
