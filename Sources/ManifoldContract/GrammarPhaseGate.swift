/// Decides whether a grammar / structured-output constraint should be applied to
/// the *upcoming* sampled token, given the thinking-phase state a backend already
/// observes for its ``ThinkingTransform``.
///
/// ## Why this exists (issue #1595)
///
/// A grammar sampler constrains a logit distribution *before* the produced token
/// has been classified as reasoning vs. visible output. With a strict schema
/// (e.g. JSON) active, that clamps a model's `<think>…</think>` reasoning tokens
/// to schema-valid text and can even mask the `<think>` markers themselves,
/// corrupting both the reasoning and the parser's block detection. Grammar and
/// thinking were therefore mutually exclusive despite both being advertised
/// capabilities.
///
/// This gate makes grammar application *phase-aware*: permissive (no grammar)
/// while the model is reasoning, strict (grammar) once the reasoning block closes.
/// A backend feeds it the events produced for each decoded token and asks
/// ``isGrammarActive`` which way to sample the next one. In `LlamaGenerationDriver`
/// that selects between two pre-built sampler chains (one with the grammar stage,
/// one without).
///
/// ## The boundary signal
///
/// `.thinkingCompleted` is the one unambiguous "reasoning has ended, visible output
/// begins" signal. It fires on the depth 1→0 transition *in the same iteration*
/// that consumes the close marker, so flipping the gate there means the **next**
/// sampled token — the first real output token — is grammar-constrained.
///
/// ## Known limitation
///
/// The gate defaults to permissive at the start because a backend cannot know,
/// before sampling, whether a thinking-capable model will actually emit a
/// `<think>` block on a given turn; defaulting to strict would mask the open
/// marker and break reasoning (the original bug). The cost: if a thinking-capable
/// model is given a grammar but chooses *not* to think on a turn (no block, so
/// `.thinkingCompleted` never fires), its output stays unconstrained. This is an
/// intentional trade-off — protecting the common "always reasons, `<think>` first"
/// contract is worth more than the rare skip-thinking-with-grammar corner. Callers
/// needing a hard grammar guarantee should disable thinking, which turns gating off
/// (`gateOnThinking == false`) and constrains from the first token.
public struct GrammarPhaseGate: Sendable {

    /// Whether the grammar constraint should be applied to the next sampled token.
    public private(set) var isGrammarActive: Bool

    /// When `false`, the gate is a no-op: grammar (if any) is active from the first
    /// token and never gated. This is the path for non-thinking models and for
    /// grammar requests with thinking disabled — behavior identical to pre-#1595.
    private let gated: Bool

    /// - Parameter gateOnThinking: pass `true` only when a grammar *and* an active
    ///   thinking parser are both present. The gate then starts permissive and
    ///   flips to strict on the first `.thinkingCompleted`. Pass `false` to keep the
    ///   grammar (or absence of one) active from the first token.
    public init(gateOnThinking: Bool) {
        self.gated = gateOnThinking
        self.isGrammarActive = !gateOnThinking
    }

    /// Observe the events produced for one decoded token and engage the grammar
    /// once the reasoning block has closed. Idempotent once active; a no-op when
    /// the gate is not gating.
    public mutating func observe(_ events: [GenerationEvent]) {
        guard gated, !isGrammarActive else { return }
        for event in events {
            if case .thinkingCompleted = event {
                isGrammarActive = true
                return
            }
        }
    }
}
