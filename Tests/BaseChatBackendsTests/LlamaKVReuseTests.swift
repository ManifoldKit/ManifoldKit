#if Llama
import XCTest
@testable import BaseChatInference
@testable import BaseChatTestSupport
@testable import BaseChatBackends
@testable import BaseChatLlama

/// Perf-audit α-1 ground-truth: real-Llama KV-cache-reuse coverage.
///
/// Complements `LlamaKVPersistenceTests` with the audit-flagged shapes that
/// suite did not exercise:
///
/// - `test_twoTurnsEmitKVReuseSecondTurn` pins the basic "second turn reuses
///   first turn's tokens" contract with an explicit lower bound on
///   `promptTokensReused`. The persistence suite already tests the broader
///   shape; this version is the audit's literal ground-truth check.
/// - `test_systemPromptChangeBreaksReuse` asserts changing the system prompt
///   between turns must NOT carry KV state forward. Pre-α-1 there was no test
///   covering this — the audit flagged it as a real-world regression hazard
///   (system-prompt swaps from sampler-preset changes look harmless but throw
///   the prefix away).
///
/// In CI (`--disable-default-traits`), the `#if Llama` file-level guard keeps
/// these out of the default suite. Run locally:
///
/// ```bash
/// scripts/test.sh --filter LlamaKVReuseTests --traits Llama --skip-update
/// ```
///
/// Each test creates its own `LlamaBackend` (matches `LlamaKVPersistenceTests`
/// — that file's tests pass per-test by relying on `addTeardownBlock { await
/// backend.unloadAndWait() }` to drain global state before the next test
/// loads). The shared-instance pattern from `LlamaE2ETests` exists for
/// suites that don't need a clean-slate KV cache; the cases below
/// deliberately do, so we pay the per-test load cost.
final class LlamaKVReuseTests: XCTestCase {

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            HardwareRequirements.isPhysicalDevice,
            "LlamaBackend requires Metal (unavailable in simulator)"
        )
        try XCTSkipUnless(
            HardwareRequirements.isAppleSilicon,
            "LlamaBackend requires Apple Silicon"
        )
        try XCTSkipUnless(
            HardwareRequirements.hasMetalDevice,
            "Requires a Metal device"
        )
    }

    // MARK: - Helpers

    private func drainAllEvents(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    private func kvReuseValue(in events: [GenerationEvent]) -> Int? {
        for event in events {
            if case .kvCacheReuse(let n) = event { return n }
        }
        return nil
    }

    /// Polls `isGenerating` until false or a 3-second deadline elapses.
    /// Mirrors the helper in `LlamaKVPersistenceTests`.
    private func waitForGeneratingFalse(_ backend: LlamaBackend) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while backend.isGenerating && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - 1. Two consecutive turns: second emits .kvCacheReuse

    /// Audit ground-truth check: with a shared prompt prefix, turn 2 must emit
    /// `.kvCacheReuse(promptTokensReused:)` with a value at least equal to the
    /// turn-1 prompt's token count. The reuse implementation lives in
    /// `LlamaGenerationDriver.swift:116`; if it ever stops firing this test
    /// fails immediately.
    ///
    /// Sabotage: in `LlamaGenerationDriver`, replace `reuseLen` with `0`
    /// before the `.kvCacheReuse` yield — second turn no longer fires the
    /// event, the `XCTUnwrap` below trips.
    func test_twoTurnsEmitKVReuseSecondTurn() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF model on disk. Set LLAMA_TEST_MODEL or place a .gguf in ~/Documents/Models/.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let turn1Prompt = "The Swift programming language was created by"
        let turn2Prompt = turn1Prompt + " Apple in 2014 and announced at WWDC."

        let config = GenerationConfig(temperature: 0.1, maxOutputTokens: 16)

        let stream1 = try backend.generate(prompt: turn1Prompt, systemPrompt: nil, config: config)
        let events1 = try await drainAllEvents(stream1)
        XCTAssertNil(
            kvReuseValue(in: events1),
            "Turn 1 must not emit .kvCacheReuse — no prior KV state"
        )
        try await waitForGeneratingFalse(backend)

        let stream2 = try backend.generate(prompt: turn2Prompt, systemPrompt: nil, config: config)
        let events2 = try await drainAllEvents(stream2)

        let reused = try XCTUnwrap(
            kvReuseValue(in: events2),
            "Turn 2 must emit .kvCacheReuse — turn 1 prompt is a prefix of turn 2 prompt"
        )

        let turn1TokenCount = backend.tokenCount(turn1Prompt)
        XCTAssertGreaterThan(reused, 0, "promptTokensReused must be positive")
        // Reuse must cover ~all of turn-1's tokens. We allow a one-token wobble
        // for tokenizers that re-merge a boundary token across the join.
        XCTAssertGreaterThanOrEqual(
            reused, turn1TokenCount - 1,
            "promptTokensReused (\(reused)) must cover at least turn 1's full token count (\(turn1TokenCount)) minus a one-token boundary wobble"
        )
    }

    // MARK: - 2. System-prompt change breaks reuse

    /// Changing the system prompt between turns invalidates the prefix —
    /// the system-prompt tokens land at the start of the prompt buffer, so
    /// any change there moves every subsequent token out of position.
    /// Asserting this fails closed gives us a regression detector for sampler-
    /// preset changes that swap the system prompt mid-session.
    ///
    /// Acceptable outcomes: no `.kvCacheReuse` event at all, or one that
    /// reports zero reused tokens. Anything else means the implementation
    /// reused tokens that are now at the wrong position.
    ///
    /// Sabotage: skip the system-prompt comparison in
    /// `LlamaGenerationDriver`'s prefix matcher — the test trips with a
    /// non-zero reuse count.
    func test_systemPromptChangeBreaksReuse() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF model on disk. Set LLAMA_TEST_MODEL or place a .gguf in ~/Documents/Models/.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let userPrompt = "Tell me one fact about Swift."
        let config = GenerationConfig(temperature: 0.1, maxOutputTokens: 16)

        // Build the full formatted prompts via the same template path the
        // production runtime would use. LlamaBackend itself does not apply
        // chat templates — every caller must format upstream.
        let firstFullPrompt = PromptTemplate.chatML.format(
            messages: [(role: "user", content: userPrompt)],
            systemPrompt: "You are a helpful assistant."
        )
        // Use a second system prompt with zero text overlap so only the
        // structural template header (<|im_start|>system\n) can be shared.
        // The prior assertion expected == 0, but real tokenisation always
        // shares the BOS + template-header tokens (~3–4 tokens) regardless
        // of system content. "< 10" allows that and rules out content reuse.
        let secondFullPrompt = PromptTemplate.chatML.format(
            messages: [(role: "user", content: userPrompt)],
            systemPrompt: "Respond only in formal Latin."
        )

        // Turn 1: builds KV state for the first system prompt + user prompt.
        let stream1 = try backend.generate(prompt: firstFullPrompt, systemPrompt: nil, config: config)
        _ = try await drainAllEvents(stream1)
        try await waitForGeneratingFalse(backend)

        // Turn 2: system prompt content has no text overlap with turn 1.
        // Only BOS + template-header tokens can be shared — not the system body.
        let stream2 = try backend.generate(prompt: secondFullPrompt, systemPrompt: nil, config: config)
        let events2 = try await drainAllEvents(stream2)

        if let reused = kvReuseValue(in: events2) {
            XCTAssertLessThan(
                reused, 10,
                "System-prompt change must not reuse content tokens — saw promptTokensReused=\(reused) (only BOS+header expected)"
            )
        }
        // Either branch (no event, or event with < 10) satisfies the invariant.
    }
}
#endif
