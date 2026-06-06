import XCTest
@testable import ManifoldInference

/// Tests for ``GrammarPhaseGate`` — the phase-aware grammar decision introduced in
/// issue #1595 so a grammar / structured-output constraint stops corrupting a
/// model's `<think>…</think>` reasoning block.
///
/// `GrammarPhaseGate.isGrammarActive` is the proxy a backend uses to pick which
/// sampler chain produces the *next* token: `false` ⇒ permissive (no grammar)
/// chain, so reasoning tokens are unconstrained; `true` ⇒ strict (grammar) chain,
/// so visible output is schema-constrained. Driving the gate with the exact event
/// stream an ``OutputParserSession`` produces (the same one
/// `LlamaGenerationDriver` feeds it) verifies the decision without a real GGUF
/// load or Metal — see issue #1595's acceptance note.
final class GrammarPhaseGateTests: XCTestCase {

    /// Replays a token-by-token generation loop: for each decoded chunk, record
    /// the sampling decision (`isGrammarActive` *before* the chunk is parsed —
    /// that is the chain that produced it), then parse the chunk and advance the
    /// gate. Returns the per-chunk decisions aligned to `chunks`.
    private func replay(
        chunks: [String],
        gateOnThinking: Bool,
        markers: ThinkingMarkers = .qwen3
    ) -> [Bool] {
        var session = OutputParserSession([.thinking(ThinkingTransform(markers: markers))])
        var gate = GrammarPhaseGate(gateOnThinking: gateOnThinking)
        var decisions: [Bool] = []
        for chunk in chunks {
            decisions.append(gate.isGrammarActive)   // which chain samples this token
            let events = session.ingest(chunk)
            gate.observe(events)
        }
        return decisions
    }

    // MARK: - Thinking model + grammar (the issue's core case)

    /// A thinking model emits a free-form `<think>` block then schema output. The
    /// gate must keep grammar OFF for every reasoning/structural token and flip it
    /// ON exactly for the first visible output token after `</think>`.
    ///
    /// Sabotage check (reasoning direction): initialise the gate with
    /// `gateOnThinking: false`. Every decision becomes `true`, so the reasoning
    /// tokens would be grammar-constrained — `reasoningDecisions` then contains
    /// `true` and the first assertion fails. That is exactly the #1595 bug.
    ///
    /// Sabotage check (output direction): make `observe` a no-op (never flip).
    /// The post-`</think>` decisions stay `false`, the second assertion fails, and
    /// the final output would be unconstrained.
    func test_thinkingModel_grammarOffWhileReasoning_onForOutput() {
        // Chunks: open marker, two reasoning chunks, close marker, then JSON output.
        let chunks = ["<think>", "let me", " think", "</think>", "{", "\"k\"", ":1", "}"]
        let decisions = replay(chunks: chunks, gateOnThinking: true)

        // Indices 0…3 are the `<think>`, reasoning, and `</think>` tokens — all
        // sampled by the permissive chain (grammar OFF). The close marker itself is
        // structural, not schema output, so it is permissive too.
        let reasoningDecisions = Array(decisions[0...3])
        XCTAssertEqual(
            reasoningDecisions, [false, false, false, false],
            "Grammar must stay inactive for the entire <think>…</think> block — "
            + "a true here means the schema is clamping reasoning tokens (the #1595 bug). "
            + "Got: \(decisions)"
        )

        // Indices 4…7 are the visible JSON tokens after `</think>` — strict chain.
        let outputDecisions = Array(decisions[4...7])
        XCTAssertEqual(
            outputDecisions, [true, true, true, true],
            "Grammar must constrain every visible output token once </think> closes. Got: \(decisions)"
        )
    }

    /// The flip must land on the FIRST post-`</think>` token, not one token late.
    /// `.thinkingCompleted` fires in the same ingest that consumes the close marker,
    /// so the very next sample is strict.
    func test_grammarEngagesOnFirstTokenAfterThinkingComplete() {
        let chunks = ["<think>", "x", "</think>", "first", "second"]
        let decisions = replay(chunks: chunks, gateOnThinking: true)
        XCTAssertEqual(decisions, [false, false, false, true, true],
                       "First visible token after </think> must already be constrained. Got: \(decisions)")
    }

    // MARK: - Non-thinking / disabled paths must be unchanged

    /// Non-thinking model (or thinking disabled): the gate never gates, so grammar
    /// is active from the first token — byte-for-byte the pre-#1595 behavior.
    ///
    /// Sabotage check: flip the constructor to `gateOnThinking: true`. The first
    /// decisions become `false` and this fails — proving the regression guard.
    func test_notGating_grammarActiveFromFirstToken() {
        let chunks = ["{", "\"k\"", ":1", "}"]
        let decisions = replay(chunks: chunks, gateOnThinking: false)
        XCTAssertEqual(decisions, [true, true, true, true],
                       "When not gating, grammar must constrain from the first token. Got: \(decisions)")
    }

    /// Even if a stray `<think>`/`</think>` appears while not gating, the gate stays
    /// active throughout — gating is purely opt-in via the constructor.
    func test_notGating_ignoresThinkingEvents() {
        let chunks = ["<think>", "noise", "</think>", "{", "}"]
        let decisions = replay(chunks: chunks, gateOnThinking: false)
        XCTAssertTrue(decisions.allSatisfy { $0 },
                      "A not-gating gate must remain active regardless of thinking events. Got: \(decisions)")
    }

    // MARK: - Gate logic unit checks

    /// `observe` is idempotent once engaged — later thinking events cannot turn the
    /// grammar back off (a model can only close its top-level reasoning block once).
    func test_observe_isIdempotentOnceActive() {
        var gate = GrammarPhaseGate(gateOnThinking: true)
        XCTAssertFalse(gate.isGrammarActive)
        gate.observe([.thinkingCompleted])
        XCTAssertTrue(gate.isGrammarActive)
        // A nested/duplicate close or stray thinking token must not reopen the gate.
        gate.observe([.thinkingToken("x")])
        gate.observe([.thinkingCompleted])
        XCTAssertTrue(gate.isGrammarActive, "Grammar must stay engaged once the block has closed")
    }

    /// `.thinkingToken` events alone (reasoning still in progress) must NOT engage
    /// the grammar — only the `.thinkingCompleted` boundary does.
    func test_thinkingTokensAloneDoNotEngageGrammar() {
        var gate = GrammarPhaseGate(gateOnThinking: true)
        gate.observe([.thinkingToken("still"), .thinkingToken(" reasoning")])
        XCTAssertFalse(gate.isGrammarActive,
                       "Grammar must remain inactive while the reasoning block is still open")
    }

    /// Documented limitation (#1595): a gating gate whose model never closes a
    /// thinking block — including the skip-thinking case where it emits visible
    /// output directly — leaves grammar inactive. Locked here so the trade-off is
    /// intentional, not accidental. Callers needing a hard guarantee disable
    /// thinking, which constructs the gate with `gateOnThinking: false`.
    func test_skipThinking_grammarStaysInactive_documentedLimitation() {
        let chunks = ["Sure", ", here", " you go"]   // visible tokens, no <think> block
        let decisions = replay(chunks: chunks, gateOnThinking: true)
        XCTAssertTrue(decisions.allSatisfy { $0 == false },
                      "Documented limitation: without a closing </think>, a gating gate stays permissive. "
                      + "Got: \(decisions)")
    }
}
