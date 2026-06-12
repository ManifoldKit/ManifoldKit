#if MLX && Llama
import XCTest
import ManifoldInference
import ManifoldTestSupport
import ManifoldBackends
@_spi(Testing) import ManifoldMLX
@_spi(Testing) import ManifoldLlama

/// Combined-trait (`#if MLX && Llama`) regression guard for the KV-cache-reuse
/// race that PR #1382 fixed — issue #1594's "race regression test under
/// `--traits MLX,Llama`" acceptance item.
///
/// ## Why this file is gated on BOTH traits
///
/// The #1382 bug was structurally invisible to CI. It lived inside `#if MLX`
/// code, and CI runs `swift test --disable-default-traits`, which never
/// compiles those blocks. The defect only surfaced during the all-traits sweep
/// (`swift build --build-tests --traits MLX,Llama,...`) that CLAUDE.md
/// prescribes. Gating this suite on `MLX && Llama` puts the regression guard in
/// exactly that sweep, pinning the discovery context so the same class of bug
/// cannot silently return.
///
/// ## Correctness model (why a non-byte-exact reuse is unrepresentable)
///
/// A turn may restore a cached KV prefix only for the leading run of tokens
/// that are a **byte-exact** match against the cached token sequence:
///
/// - **Llama** computes the reuse length as
///   `zip(newTokens, cachedTokens).prefix(while: { $0 == $1 }).count`
///   (`LlamaBackend.generate`) and trims the C KV cache tail beyond it with
///   `llama_memory_seq_rm`. The first divergent token ends the prefix.
/// - **MLX** restores the cached prompt cache, then clamps the resume offset to
///   the shared prefix length; generation can only ever resume from a position
///   that was decoded identically on the prior turn.
///
/// Because the reuse length is *derived* from the common-prefix scan rather than
/// assumed from a length or a hash, any divergence (system-prompt edit, branch,
/// re-tokenization) trims reuse to the actual common prefix. Over-reuse is not a
/// guarded path — it is unrepresentable.
///
/// ## What runs where
///
/// - Tests A and B drive the MLX generation path through `MockMLXModelContainer`
///   and run in CI without Metal/Apple Silicon — they pin the #1382 stale-snapshot
///   shape and the byte-exact prefix-trim guarantee at the token level.
/// - Test C is a real-GGUF byte-exact determinism check. Metal is unavailable in
///   the simulator and no model may be present, so it skips cleanly unless a
///   physical Apple-Silicon device with a discoverable model is available. It is
///   never faked.
final class KVCacheReuseRaceRegressionTests: XCTestCase {

    // MARK: - Helpers

    private func drainEvents(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    private func reuseCounts(in events: [GenerationEvent]) -> [Int] {
        events.compactMap { event in
            if case .kvCacheReuse(let count) = event { return count }
            return nil
        }
    }

    private func visibleText(in events: [GenerationEvent]) -> String {
        events.reduce(into: "") { acc, event in
            if case .token(let text) = event { acc += text }
        }
    }

    // MARK: - A. #1382 stale-snapshot race (MLX, runs in CI via mock)

    /// The #1382 defect: `MLXBackend.generate()` synchronously captured
    /// `_promptCacheState.snapshot` at call entry — *before* the prior turn's
    /// asynchronous snapshot-capture task had written it. The second turn
    /// therefore read a nil/stale snapshot and emitted `.kvCacheReuse(0)` (a
    /// cache miss) even though the prompt prefix matched exactly.
    ///
    /// The fix replaced the eager capture with a `currentSnapshot` closure the
    /// driver invokes *after* awaiting `pendingSnapshotTask`. This test pins that
    /// behaviour: when turn 2 starts while turn 1's snapshot task is still
    /// in-flight (the exact race window), reuse must still fire for the full
    /// shared prefix.
    ///
    /// Sabotage: reading the eagerly-captured snapshot instead of the closure
    /// (the pre-#1382 code) makes `reuseCounts` `[0]` and trips both assertions.
    func test_mlx_secondTurnReusesPrefixWhileSnapshotTaskStillPending() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]
        mock.preparedTokenBatches = [
            [101, 102, 103, 104],
            [101, 102, 103, 104, 105],
        ]

        let backend = MLXBackend(enableKVCacheReuse: true)
        backend._inject(mock)

        _ = try await drainEvents(try backend.generate(
            prompt: "turn-1",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        // After turn 1's stream finishes, the snapshot lineage exists (the
        // capture task is scheduled before the stream's continuation finishes).
        // This is the #1382 race window: turn 2 begins while the task may not
        // yet have written `snapshot`. We do NOT wait for it to settle.
        XCTAssertTrue(
            backend._hasPromptCacheSnapshotForTesting(),
            "Turn 1 must schedule a snapshot lineage — without it the race window doesn't exist and the test is vacuous"
        )

        let secondEvents = try await drainEvents(try backend.generate(
            prompt: "turn-2",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        XCTAssertEqual(
            reuseCounts(in: secondEvents), [4],
            "Turn 2 must reuse the full 4-token shared prefix even when started during the snapshot task's in-flight window (#1382)"
        )
        XCTAssertEqual(
            mock.lastInitialCacheOffsets, [4],
            "Generation must resume from the restored 4-token prefix, not a cold cache"
        )
    }

    // MARK: - B. Byte-exact prefix trim on divergence (MLX, runs in CI via mock)

    /// The structural guarantee against the #1382 hazard: reuse is derived from
    /// the byte-exact common prefix, so a divergent prompt can never reuse past
    /// the first differing token. Turn 1 = `[201,202,203,204]`,
    /// turn 2 = `[201,202,999,205]` share exactly two leading tokens, so reuse
    /// must be exactly 2 — never 3 or 4.
    ///
    /// Sabotage: changing turn 2's batch to `[201,999,...]` drops the expected
    /// reuse to 1; keeping `[201,202,203,...]` raises it to 3. Either makes the
    /// `[2]` assertions fail, proving the trim tracks the true common prefix.
    func test_mlx_divergentPromptReusesOnlyByteExactCommonPrefix() async throws {
        let mock = MockMLXModelContainer()
        mock.tokensToYield = ["ok"]
        mock.preparedTokenBatches = [
            [201, 202, 203, 204],
            [201, 202, 999, 205],
        ]

        let backend = MLXBackend(enableKVCacheReuse: true)
        backend._inject(mock)

        _ = try await drainEvents(try backend.generate(
            prompt: "turn-1",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        let secondEvents = try await drainEvents(try backend.generate(
            prompt: "turn-2",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        XCTAssertEqual(
            reuseCounts(in: secondEvents), [2],
            "Only the 2-token byte-exact common prefix may be reused after divergence at token index 2"
        )
        XCTAssertEqual(
            mock.lastInitialCacheOffsets, [2],
            "Restored cache must be trimmed to the byte-exact common prefix before generation resumes"
        )
    }

    // MARK: - C. Real-GGUF byte-exact determinism across the reuse boundary

    /// The true byte-exact correctness property #1382 threatened: a warm second
    /// turn (reuse ON, started from a cached prefix) must produce a token stream
    /// byte-identical to a cold second turn (a fresh backend that decodes the
    /// same prompt from scratch). Greedy decoding (`temperature: 0`) makes the
    /// argmax path deterministic, so any divergence means the reuse path's KV
    /// state was not equivalent to a full prefill — exactly the hazard class.
    ///
    /// The `LlamaBackend` re-decodes the final two prompt tokens as a batched
    /// pair (#966) so the warm path's Metal reduction order matches the cold
    /// path's; this test is the regression guard for that determinism.
    ///
    /// Skips cleanly off-device or with no model — never faked.
    func test_llama_warmReuseTurnMatchesColdTurnByteForByte() async throws {
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
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF model on disk. Set LLAMA_TEST_MODEL or place a .gguf in ~/Documents/Models/.")
        }

        let turn1Prompt = "The Swift programming language was created by"
        let turn2Prompt = turn1Prompt + " Apple, and it is used to build apps."
        // temperature 0 → greedy argmax → deterministic output, the precondition
        // for a meaningful byte-for-byte comparison.
        let config = GenerationConfig(temperature: 0.0, maxOutputTokens: 24)

        // Warm path: backend does turn 1, then turn 2 reusing the shared prefix.
        let warmBackend = LlamaBackend()
        addTeardownBlock { await warmBackend.unloadAndWait() }
        try await warmBackend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        _ = try await drainEvents(try warmBackend.generate(prompt: turn1Prompt, systemPrompt: nil, config: config))
        let warmEvents = try await drainEvents(try warmBackend.generate(prompt: turn2Prompt, systemPrompt: nil, config: config))
        let warmReuse = reuseCounts(in: warmEvents)
        let warmText = visibleText(in: warmEvents)

        // Cold path: a fresh backend that has no prior KV state, decoding the
        // same turn-2 prompt from scratch.
        let coldBackend = LlamaBackend()
        addTeardownBlock { await coldBackend.unloadAndWait() }
        try await coldBackend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let coldEvents = try await drainEvents(try coldBackend.generate(prompt: turn2Prompt, systemPrompt: nil, config: config))
        let coldText = visibleText(in: coldEvents)

        XCTAssertGreaterThan(
            warmReuse.first ?? 0, 0,
            "Warm second turn must actually reuse a prefix (>0) or the determinism comparison is vacuous"
        )
        XCTAssertEqual(
            warmText, coldText,
            "Warm (KV-reuse) and cold (full-prefill) second turns must produce byte-identical greedy output — a mismatch is the #1382 non-exact-reuse hazard"
        )

        // Sabotage: removing the #966 last-two-token batched re-decode in
        // LlamaBackend.generate (capping reuse at tokens.count - 1 instead of
        // - 2) flips the argmax on near-tied logits and diverges warmText.
    }
}
#endif
