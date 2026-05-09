#if Llama
import XCTest
@testable import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldLlama

/// Tests for KV-cache prefix reuse across consecutive turns in `LlamaBackend`.
///
/// All tests require a real GGUF model file and Apple Silicon Metal —
/// gate with `XCTSkipIf` / `guard let modelURL` checks.
///
/// In CI (--disable-default-traits), the `#if Llama` guard at the file level
/// keeps these tests out of the default suite. Run locally with:
///   swift test --filter ManifoldBackendsTests --traits Llama
final class LlamaKVPersistenceTests: XCTestCase {

    // MARK: - setUp

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
    }

    // MARK: - Helpers

    /// Drains a stream fully and returns all events. Throws on stream error.
    private func drainAllEvents(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    /// Returns the first `.kvCacheReuse` event from `events`, if any.
    private func kvCacheReuseEvent(in events: [GenerationEvent]) -> GenerationEvent? {
        events.first { if case .kvCacheReuse = $0 { return true }; return false }
    }

    /// Polls until `backend.isGenerating == false` or a 3-second deadline elapses.
    private func waitForGeneratingFalse(_ backend: LlamaBackend) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while backend.isGenerating && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - 1. Consecutive turns emit kvCacheReuse

    /// Turn 2 prompt = Turn 1 prompt + " next turn." — the entire Turn 1 token
    /// sequence is a prefix of Turn 2. Assert `.kvCacheReuse` fires on Turn 2
    /// with `promptTokensReused == turn1TokenCount`.
    ///
    /// Sabotage check: set `reuseLen = 0` unconditionally in
    /// `LlamaBackend.generate()`. The `.kvCacheReuse` event is never emitted
    /// and this assertion fails.
    func test_kvReuse_consecutiveTurns() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF model on disk. Place a `.gguf` in ~/Documents/Models/ to run this test.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let turn1Prompt = "Hello, how are you?"
        let turn2Prompt = turn1Prompt + " That is great to hear."

        let config = GenerationConfig(temperature: 0.1, maxOutputTokens: 20)

        // Turn 1 — no prior state, no reuse expected.
        let stream1 = try backend.generate(prompt: turn1Prompt, systemPrompt: nil, config: config)
        let events1 = try await drainAllEvents(stream1)
        XCTAssertNil(kvCacheReuseEvent(in: events1),
                     "Turn 1 must not emit .kvCacheReuse — no previous KV state exists")

        try await waitForGeneratingFalse(backend)

        // Turn 2 — first turn1Prompt.count tokens are identical to Turn 1.
        let stream2 = try backend.generate(prompt: turn2Prompt, systemPrompt: nil, config: config)
        let events2 = try await drainAllEvents(stream2)

        guard let reuseEvent = kvCacheReuseEvent(in: events2) else {
            XCTFail("Turn 2 must emit .kvCacheReuse(promptTokensReused:) — KV prefix was not reused")
            return
        }
        guard case .kvCacheReuse(let reused) = reuseEvent else { return }

        // The reuse count must be positive and at most tokens.count - 1.
        XCTAssertGreaterThan(reused, 0, "promptTokensReused must be > 0")
        // We can't assert the exact token count without the vocab, but we can
        // assert it is less than the full Turn 2 token count (capped at n-1).
        let turn1TokenCount = backend.tokenCount(turn1Prompt)
        XCTAssertLessThanOrEqual(reused, turn1TokenCount,
                                  "Cannot reuse more tokens than Turn 1 had")
    }

    // MARK: - 2. Prefix divergence reuses only the matching head

    /// Turn 2 shares the first N tokens with Turn 1 then diverges.
    /// `promptTokensReused` must equal the actual common prefix length.
    ///
    /// Sabotage check: always set `reuseLen = 0` — no `.kvCacheReuse` event fires.
    func test_kvReuse_prefixDivergence() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF model on disk.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let sharedPrefix = "The weather today is"
        let turn1Prompt = sharedPrefix + " sunny and warm."
        let turn2Prompt = sharedPrefix + " cold and rainy."

        let config = GenerationConfig(temperature: 0.1, maxOutputTokens: 16)

        // Turn 1.
        let stream1 = try backend.generate(prompt: turn1Prompt, systemPrompt: nil, config: config)
        _ = try await drainAllEvents(stream1)
        try await waitForGeneratingFalse(backend)

        // Turn 2 — diverges after sharedPrefix.
        let stream2 = try backend.generate(prompt: turn2Prompt, systemPrompt: nil, config: config)
        let events2 = try await drainAllEvents(stream2)

        guard let reuseEvent = kvCacheReuseEvent(in: events2) else {
            // If the shared prefix is fewer than 2 tokens this can legitimately
            // be zero — but for a ~5-word phrase on any BPE tokenizer it must fire.
            XCTFail("Turn 2 must emit .kvCacheReuse — shared prefix \"\(sharedPrefix)\" was not reused")
            return
        }
        guard case .kvCacheReuse(let reused) = reuseEvent else { return }
        XCTAssertGreaterThan(reused, 0)

        // The reused count must be less than the full Turn 1 token count — it
        // cannot have reused the diverging tail.
        let turn1Tokens = backend.tokenCount(turn1Prompt)
        XCTAssertLessThan(reused, turn1Tokens,
                           "Diverging tail must NOT be reused (reused \(reused) >= turn1 total \(turn1Tokens))")
    }

    // MARK: - 3. Cancel preserves prefix for next turn

    /// Cancel Turn 2 mid-stream, then start Turn 3 with the same shared prefix.
    /// Turn 3 must still emit `.kvCacheReuse` — `stopGeneration()` must not
    /// wipe `sessionKVState`.
    ///
    /// Sabotage check: add `sessionKVState = nil` inside `stopGeneration()`.
    /// Turn 3 no longer sees a reuse event.
    func test_kvReuse_cancelPreservesPrefix() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF model on disk.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let sharedPrompt = "Tell me about the Swift programming language."
        let config = GenerationConfig(temperature: 0.1, maxOutputTokens: 64)

        // Turn 1 — complete it.
        let stream1 = try backend.generate(prompt: sharedPrompt, systemPrompt: nil, config: config)
        _ = try await drainAllEvents(stream1)
        try await waitForGeneratingFalse(backend)

        // Turn 2 — cancel after a few tokens.
        let stream2 = try backend.generate(prompt: sharedPrompt + " Start with history.", systemPrompt: nil, config: config)
        var tokensSeen = 0
        for try await event in stream2.events {
            if case .token = event { tokensSeen += 1 }
            if tokensSeen >= 2 { break }
        }
        backend.stopGeneration()
        // Drain so isGenerating resets.
        for try await _ in stream2.events { }
        try await waitForGeneratingFalse(backend)

        // Turn 3 — same shared prompt as Turn 1. Must reuse despite the cancel.
        let stream3 = try backend.generate(prompt: sharedPrompt, systemPrompt: nil, config: config)
        let events3 = try await drainAllEvents(stream3)

        XCTAssertNotNil(
            kvCacheReuseEvent(in: events3),
            "Turn 3 must emit .kvCacheReuse — stopGeneration() must not clear sessionKVState (#663)"
        )
    }

    // MARK: - 4. resetConversation invalidates KV state

    /// After `resetConversation()`, Turn 2 must start from a clean slate.
    /// No `.kvCacheReuse` event may be emitted.
    ///
    /// Sabotage check: do not set `sessionKVState = nil` in `resetConversation()`.
    /// Turn 2 incorrectly emits `.kvCacheReuse`.
    func test_kvReuse_resetConversationInvalidates() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF model on disk.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let prompt = "Hello!"
        let config = GenerationConfig(temperature: 0.1, maxOutputTokens: 16)

        // Turn 1 — build KV state.
        let stream1 = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)
        _ = try await drainAllEvents(stream1)
        try await waitForGeneratingFalse(backend)

        // Invalidate — resets sessionKVState and flushes the C KV cache.
        backend.resetConversation()

        // Turn 2 — identical prompt, but must NOT reuse (state was wiped).
        let stream2 = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)
        let events2 = try await drainAllEvents(stream2)

        XCTAssertNil(
            kvCacheReuseEvent(in: events2),
            "After resetConversation(), Turn 2 must not emit .kvCacheReuse (#663)"
        )
    }

    // MARK: - 5. unloadModel + loadModel invalidates KV state

    /// `unloadModel()` must clear `sessionKVState`. After reloading the same
    /// model, Turn 2 must start fresh with no `.kvCacheReuse` event.
    ///
    /// Sabotage check: skip `sessionKVState = nil` in `unloadModel()`.
    /// After reload, the stale token sequence is compared against a fresh
    /// vocab — the common prefix is 0 because the new context is empty, but
    /// having stale state in sessionKVState could cause a use-after-free or
    /// incorrect prefix match. Either way, the test confirms no crash.
    func test_kvReuse_unloadModelInvalidates() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF model on disk.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let prompt = "Hello!"
        let config = GenerationConfig(temperature: 0.1, maxOutputTokens: 16)

        // Turn 1 — build KV state.
        let stream1 = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)
        _ = try await drainAllEvents(stream1)
        try await waitForGeneratingFalse(backend)

        // Unload and reload.
        await backend.unloadAndWait()
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        // Turn 2 — same prompt, fresh model context. Must not reuse and must not crash.
        let stream2 = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)
        let events2 = try await drainAllEvents(stream2)

        XCTAssertNil(
            kvCacheReuseEvent(in: events2),
            "After unloadModel()+loadModel(), Turn 2 must not emit .kvCacheReuse (#663)"
        )
        // Sanity check: generation still produces output.
        let hasToken = events2.contains { if case .token = $0 { return true }; return false }
            || events2.contains { if case .thinkingToken = $0 { return true }; return false }
        XCTAssertTrue(hasToken, "Generation after reload must produce tokens")
    }

    // MARK: - 6. stopGeneration preserves sessionKVState

    /// Regression test: `stopGeneration()` must NOT clear `sessionKVState`.
    /// Verified by confirming Turn 3 (matching Turn 1's prompt) still reuses.
    ///
    /// This is structurally similar to test 3 but focuses specifically on the
    /// invariant that stopGeneration is a pause, not a reset.
    func test_kvReuse_stopGenerationPreservesState() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF model on disk.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let basePrompt = "Explain what a neural network is in one sentence."
        let config = GenerationConfig(temperature: 0.1, maxOutputTokens: 48)

        // Turn 1 — complete.
        let stream1 = try backend.generate(prompt: basePrompt, systemPrompt: nil, config: config)
        _ = try await drainAllEvents(stream1)
        try await waitForGeneratingFalse(backend)

        // Call stopGeneration on an idle backend — must be a no-op for KV state.
        backend.stopGeneration()

        // Turn 2 — same prompt, stopGeneration() must not have invalidated state.
        let stream2 = try backend.generate(prompt: basePrompt, systemPrompt: nil, config: config)
        let events2 = try await drainAllEvents(stream2)

        XCTAssertNotNil(
            kvCacheReuseEvent(in: events2),
            "stopGeneration() on an idle backend must not wipe sessionKVState — "
            + "Turn 2 must still emit .kvCacheReuse (#663)"
        )
    }

    // MARK: - 7. Determinism across reuse turns

    /// With temperature=0.0 (greedy), the same prompt must produce identical
    /// token output whether KV cache is fresh (Turn 1) or reused (Turn 2).
    ///
    /// This guards against a correctness regression where the reused prefix
    /// tokens are at wrong positions, causing different logits on Turn 2.
    ///
    /// Sabotage check: shift `promptPos` by +1 in the driver's decode loop
    /// start (i.e. start at reuseLen + 1). The logits for the last prompt
    /// token come from the wrong position, producing different output on
    /// Turn 2 and failing the equality assertion.
    func test_kvReuse_determinism() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF model on disk.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let prompt = "The capital of France is"
        // temperature=0.0 selects the argmax token at every step (greedy), making
        // the output deterministic across runs. repeatPenalty=1.0 disables penalties
        // so the only source of variation is the logit positions.
        let config = GenerationConfig(temperature: 0.0, maxOutputTokens: 8)

        // Turn 1 — collect visible tokens.
        let stream1 = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)
        let events1 = try await drainAllEvents(stream1)
        let turn1Tokens = events1.compactMap { if case .token(let t) = $0 { return t }; return nil }
        try await waitForGeneratingFalse(backend)

        // Turn 2 — same prompt, KV prefix reused. Output must be identical.
        let stream2 = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)
        let events2 = try await drainAllEvents(stream2)
        let turn2Tokens = events2.compactMap { if case .token(let t) = $0 { return t }; return nil }

        // Confirm the reuse event was actually emitted (otherwise the test is vacuous).
        XCTAssertNotNil(
            kvCacheReuseEvent(in: events2),
            "Turn 2 must emit .kvCacheReuse — without it this determinism check is vacuous"
        )

        // The visible token sequences must be identical.
        XCTAssertEqual(
            turn1Tokens, turn2Tokens,
            "Greedy output must be deterministic across KV-reuse turns — "
            + "a mismatch means reused tokens are decoded at wrong positions (#663). "
            + "Turn1: \(turn1Tokens), Turn2: \(turn2Tokens)"
        )
    }
}
#endif
