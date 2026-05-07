import XCTest
import BaseChatRuntime
import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatTestSupport

/// One assertion per failure mode on `ChaosBackend`. These tests lock in the
/// contract each mode promises to deliver so UI-layer regressions have a
/// stable fixture to point at.
final class ChaosBackendTests: XCTestCase {

    private let modelURL = URL(fileURLWithPath: "/tmp/fake-model")
    private let allTokens = ["a", "b", "c", "d", "e"]

    private func collect(_ backend: ChaosBackend) async -> (tokens: [String], error: Error?) {
        let stream: GenerationStream
        do {
            stream = try backend.generate(prompt: "x", systemPrompt: nil, config: GenerationConfig())
        } catch {
            return ([], error)
        }
        var collected: [String] = []
        do {
            for try await event in stream.events {
                if case .token(let t) = event { collected.append(t) }
            }
            return (collected, nil)
        } catch {
            return (collected, error)
        }
    }

    func test_noneMode_yieldsEverything() async throws {
        let backend = ChaosBackend(mode: .none, tokensToYield: allTokens)
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
        let (tokens, error) = await collect(backend)
        XCTAssertNil(error)
        XCTAssertEqual(tokens, allTokens)
    }

    func test_dropMidStream_truncatesWithoutThrowing() async throws {
        let backend = ChaosBackend(mode: .dropMidStream(afterTokens: 2), tokensToYield: allTokens)
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
        let (tokens, error) = await collect(backend)
        XCTAssertNil(error, "dropMidStream must silently finish, not throw")
        XCTAssertEqual(tokens, ["a", "b"])
    }

    func test_slowFirstToken_delaysBeforeFirstEvent() async throws {
        let delay: Duration = .milliseconds(50)
        let backend = ChaosBackend(mode: .slowFirstToken(delay: delay), tokensToYield: allTokens)
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let clock = ContinuousClock()
        let start = clock.now
        let (tokens, error) = await collect(backend)
        let elapsed = start.duration(to: clock.now)

        XCTAssertNil(error)
        XCTAssertEqual(tokens, allTokens)
        XCTAssertGreaterThanOrEqual(
            elapsed, delay,
            "slowFirstToken must wait the configured delay before streaming"
        )
    }

    func test_burstThenStall_pausesMidStream() async throws {
        let stall: Duration = .milliseconds(50)
        let backend = ChaosBackend(
            mode: .burstThenStall(burstSize: 2, stallDuration: stall),
            tokensToYield: allTokens
        )
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let clock = ContinuousClock()
        let start = clock.now
        let (tokens, error) = await collect(backend)
        let elapsed = start.duration(to: clock.now)

        XCTAssertNil(error)
        XCTAssertEqual(tokens, allTokens)
        XCTAssertGreaterThanOrEqual(
            elapsed, stall,
            "burstThenStall must include at least one stall period"
        )
    }

    /// Back-to-back `generate()` calls must each produce a fresh stream and
    /// leave `isGenerating == false` between runs. This catches regressions
    /// in the lifecycle helper's task-slot clearing.
    func test_backToBackGenerate_eachCallProducesFreshStream() async throws {
        let backend = ChaosBackend(mode: .none, tokensToYield: ["x", "y"])
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let (firstTokens, firstError) = await collect(backend)
        XCTAssertNil(firstError)
        XCTAssertEqual(firstTokens, ["x", "y"])
        XCTAssertFalse(backend.isGenerating, "isGenerating must reset after first run")

        let (secondTokens, secondError) = await collect(backend)
        XCTAssertNil(secondError)
        XCTAssertEqual(secondTokens, ["x", "y"], "Second run must yield the same token sequence")
        XCTAssertFalse(backend.isGenerating, "isGenerating must reset after second run")
    }

    func test_networkError_throwsAfterPartialStream() async throws {
        let backend = ChaosBackend(mode: .networkError(afterTokens: 3), tokensToYield: allTokens)
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
        let (tokens, error) = await collect(backend)
        XCTAssertEqual(tokens, ["a", "b", "c"])
        XCTAssertNotNil(error, "networkError must surface an error on the stream")
        guard case .inferenceFailure = error as? InferenceError else {
            XCTFail("Expected InferenceError.inferenceFailure, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(backend.errorsThrownCount.load(ordering: .relaxed), 1,
                       "errorsThrownCount must reflect the one injected network error")
    }

    // MARK: - T1.2 additions: idle timeout, malformed tool call, parallel tool calls

    /// `idleTimeout` yields N tokens then goes silent without finishing for
    /// `silenceFor` before the body returns. Asserts:
    /// - exactly N tokens delivered (no more)
    /// - elapsed time ≥ silenceFor (the body really did wait)
    /// - the stream finishes naturally (no error surfaced)
    ///
    /// Sabotage-evidence:
    ///   M1: in ChaosBackend.runFailureMode `case .idleTimeout`, comment out the
    ///       `try? await Task.sleep(for: silenceFor)` line; this test fails because
    ///       elapsed ≪ silenceFor (the assertion at the bottom would not fire).
    ///   M2: change the silenceFor literal from `.milliseconds(80)` to `.milliseconds(1)`;
    ///       this test fails because elapsed (~80ms) is far above the assertion threshold,
    ///       proving the test value-checks against the actual constant.
    ///   M3: the test does not gate on a backend capability; idleTimeout is universal.
    func test_idleTimeout_emitsPrefixThenStallsForDuration() async throws {
        let silenceFor: Duration = .milliseconds(80)
        let backend = ChaosBackend(
            mode: .idleTimeout(afterTokens: 2, silenceFor: silenceFor),
            tokensToYield: allTokens
        )
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let clock = ContinuousClock()
        let start = clock.now
        let (tokens, error) = await collect(backend)
        let elapsed = start.duration(to: clock.now)

        XCTAssertNil(error, "idleTimeout must finish naturally, not throw")
        XCTAssertEqual(tokens, ["a", "b"])
        XCTAssertGreaterThanOrEqual(
            elapsed, silenceFor,
            "idleTimeout must include at least one silence period of the configured duration"
        )
        XCTAssertEqual(backend.tokensEmittedCount.load(ordering: .relaxed), 2,
                       "tokensEmittedCount must reflect the prefix that was yielded before silence")
    }

    /// `malformedToolCall` yields tokens then a `.toolCall` event whose
    /// arguments string is invalid JSON. Asserts the tool-call event reaches
    /// the consumer with the OOD nonce arguments verbatim — downstream parser
    /// robustness is the consumer's responsibility, but the chaos backend
    /// must reliably *deliver* a malformed payload for that test to exist.
    ///
    /// Sabotage-evidence:
    ///   M1: in ChaosBackend.runFailureMode `case .malformedToolCall`, comment out
    ///       `continuation.yield(.toolCall(...))`; this test fails because
    ///       `toolCallsCollected` is empty.
    ///   M2: change the OOD nonce `"{not-json-§NONCE§}"` to `"{}"`; this test fails
    ///       because the asserted-against literal still contains "§NONCE§".
    ///   M3: not capability-gated.
    func test_malformedToolCall_emitsToolCallWithBrokenArgsVerbatim() async throws {
        let nonce = "§NONCE§\(UUID().uuidString.prefix(8))"
        let invalidJSON = "{not-json-\(nonce)}"
        let backend = ChaosBackend(
            mode: .malformedToolCall(
                tokensBefore: 1,
                callId: "call-2099-01-01",
                toolName: "broken_tool",
                invalidJSON: invalidJSON
            ),
            tokensToYield: allTokens
        )
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let stream = try backend.generate(prompt: "x", systemPrompt: nil, config: GenerationConfig())
        var tokens: [String] = []
        var toolCallsCollected: [ToolCall] = []
        for try await event in stream.events {
            switch event {
            case .token(let t): tokens.append(t)
            case .toolCall(let call): toolCallsCollected.append(call)
            default: break
            }
        }

        XCTAssertEqual(tokens, ["a"])
        XCTAssertEqual(toolCallsCollected.count, 1)
        XCTAssertEqual(toolCallsCollected.first?.id, "call-2099-01-01")
        XCTAssertEqual(toolCallsCollected.first?.toolName, "broken_tool")
        XCTAssertEqual(toolCallsCollected.first?.arguments, invalidJSON,
                       "ChaosBackend must deliver invalid-JSON arguments verbatim — including the nonce")
        XCTAssertEqual(backend.toolCallsEmittedCount.load(ordering: .relaxed), 1)
    }

    /// `parallelToolCalls` yields `count` tool-call events back-to-back.
    /// Asserts all `count` are delivered with monotonic indices.
    ///
    /// Sabotage-evidence:
    ///   M1: in ChaosBackend.runFailureMode `case .parallelToolCalls`, change
    ///       the loop to `for index in 0..<1`; this test fails because only one
    ///       tool call is emitted.
    ///   M2: change `idPrefix: "fan-"` to `"x"`; the assertion on first id flips.
    ///   M3: not capability-gated.
    func test_parallelToolCalls_yieldsCountEventsWithMonotonicIds() async throws {
        let backend = ChaosBackend(
            mode: .parallelToolCalls(count: 4, idPrefix: "fan-", toolName: "echo")
        )
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let stream = try backend.generate(prompt: "x", systemPrompt: nil, config: GenerationConfig())
        var calls: [ToolCall] = []
        for try await event in stream.events {
            if case .toolCall(let call) = event { calls.append(call) }
        }

        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.map(\.id), ["fan-0", "fan-1", "fan-2", "fan-3"])
        XCTAssertEqual(calls.map(\.toolName), Array(repeating: "echo", count: 4))
        XCTAssertEqual(backend.toolCallsEmittedCount.load(ordering: .relaxed), 4)
    }

    /// Counters accumulate across multiple `generate()` calls on the same
    /// backend instance. Confirms the meta-property the new fields claim.
    func test_counters_accumulateAcrossGenerateCalls() async throws {
        let backend = ChaosBackend(mode: .none, tokensToYield: ["x", "y"])
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
        _ = await collect(backend)
        _ = await collect(backend)
        XCTAssertEqual(backend.tokensEmittedCount.load(ordering: .relaxed), 4,
                       "tokensEmittedCount must accumulate (2 + 2 = 4)")
        XCTAssertEqual(backend.toolCallsEmittedCount.load(ordering: .relaxed), 0)
        XCTAssertEqual(backend.errorsThrownCount.load(ordering: .relaxed), 0)
    }
}
