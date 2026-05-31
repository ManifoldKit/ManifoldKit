#if DEBUG
import Foundation
import ManifoldRuntime

/// The shared scenario registry — the single source of truth for both the
/// CI test matrix and the demo picker.
///
/// Add new scenarios here as static properties; they are automatically
/// included in ``all`` and therefore in both the test matrix and the demo UI.
public enum RuntimeScenarioRegistry {

    /// All registered scenarios. Tests enumerate this to build the CI matrix;
    /// the demo picker reads it to populate its scenario list.
    public static let all: [RuntimeScenario] = [
        .basicTokenStream,
        .kvCacheReuseAdvisory,
        .diagnosticThrottleAdvisory,
        .multiTurnConversation,
        // P4b batch:
        .swapTheBrain,
        .midStreamErrorRecovery,
        .researcherWriterHandoff,
        // P4a: flagship scenario:
        .researchSession,
    ]
}

// MARK: - Built-in scenarios

extension RuntimeScenario {

    /// Simplest possible scenario: single turn, plain token stream.
    public static let basicTokenStream = RuntimeScenario(
        id: "basic-token-stream",
        displayName: "Basic Token Stream",
        scenarioDescription: "A single-turn conversation that yields plain text tokens. Verifies the core send → stream → finish lifecycle.",
        userMessages: ["Hello, world."],
        scriptedTurns: [
            .tokens(["Hello", ",", " world", "!"])
        ],
        expectedSubsequence: [
            .streamStarted,
            .tokenEmitted,
            .streamFinished,
        ]
    )

    /// Verifies that a backend emitting `kvCacheReuse` advisory events does
    /// not abort generation — the runtime must pass through to `streamFinished`.
    public static let kvCacheReuseAdvisory = RuntimeScenario(
        id: "kv-cache-reuse-advisory",
        displayName: "KV Cache Reuse Advisory",
        scenarioDescription: "Backend emits a kvCacheReuse event before tokens. Verifies the runtime does not treat the advisory as an error.",
        userMessages: ["Repeat the prior context."],
        scriptedTurns: [
            .kvCacheReuse(reuseCount: 256, then: ["Cache", " hit", "."])
        ],
        expectedSubsequence: [
            .streamStarted,
            .tokenEmitted,
            .streamFinished,
        ]
    )

    /// Verifies that a `diagnosticThrottle` advisory does not abort generation.
    public static let diagnosticThrottleAdvisory = RuntimeScenario(
        id: "diagnostic-throttle-advisory",
        displayName: "Diagnostic Throttle Advisory",
        scenarioDescription: "Backend emits a diagnosticThrottle event before tokens. Verifies the runtime treats the advisory as informational.",
        userMessages: ["What is the throttle status?"],
        scriptedTurns: [
            .throttle(reason: "rate-limit-burst", then: ["Throttle", " noted", "."])
        ],
        expectedSubsequence: [
            .streamStarted,
            .tokenEmitted,
            .streamFinished,
        ]
    )

    /// Two-turn conversation. Verifies the full send → finish lifecycle repeats
    /// correctly across turns without state leakage.
    public static let multiTurnConversation = RuntimeScenario(
        id: "multi-turn-conversation",
        displayName: "Multi-Turn Conversation",
        scenarioDescription: "Two sequential turns. Verifies the runtime correctly resets per-turn state between sends.",
        userMessages: [
            "First turn.",
            "Second turn.",
        ],
        scriptedTurns: [
            .tokens(["Turn", " one", "."]),
            .tokens(["Turn", " two", "."]),
        ],
        expectedSubsequence: [
            .streamStarted, .tokenEmitted, .streamFinished,
            .streamStarted, .tokenEmitted, .streamFinished,
        ]
    )

    // MARK: - P4b scenarios

    /// Simulates a capability-degraded backend: the first turn produces a rich
    /// response; the second produces a minimal, token-poor response as if the
    /// underlying model had been downgraded. Verifies the runtime completes both
    /// turns cleanly regardless of response quality.
    public static let swapTheBrain = RuntimeScenario(
        id: "swap-the-brain",
        displayName: "Swap the Brain",
        scenarioDescription: "Two-turn conversation where the second turn simulates a capability-degraded backend response (fewer tokens). Verifies the runtime completes cleanly with minimal output.",
        userMessages: [
            "Explain the theory of relativity in detail.",
            "Summarise that in one word.",
        ],
        scriptedTurns: [
            .tokens(["Mass", " warps", " spacetime", "."]),  // full response
            .tokens(["Spacetime", "."]),                      // degraded — minimal
        ],
        expectedSubsequence: [
            .streamStarted, .tokenEmitted, .streamFinished,
            .streamStarted, .tokenEmitted, .streamFinished,
        ]
    )

    /// First turn errors mid-stream; second turn succeeds. Verifies that
    /// `errorRaised` appears in the trace after the partial first turn and
    /// that the runtime remains usable for the subsequent turn.
    public static let midStreamErrorRecovery = RuntimeScenario(
        id: "mid-stream-error-recovery",
        displayName: "Mid-Stream Error Recovery",
        scenarioDescription: "First turn errors mid-stream; second turn succeeds. Verifies errorRaised appears and the runtime stays usable for the next turn.",
        userMessages: [
            "What is 2 + 2?",
            "Try again.",
        ],
        scriptedTurns: [
            .failMidStream(
                NSError(domain: "ScenarioTest", code: 503, userInfo: [NSLocalizedDescriptionKey: "upstream timeout"]),
                afterTokens: 1,
                tokens: ["Four"]
            ),
            .tokens(["Four", "."]),
        ],
        expectedSubsequence: [
            .streamStarted, .tokenEmitted, .errorRaised,
            .streamStarted, .tokenEmitted, .streamFinished,
        ]
    )

    /// Two-phase conversation that models a researcher → writer agent handoff:
    /// the first turn represents the researcher phase (context-gathering tokens)
    /// and the second represents the writer phase (synthesis tokens). Verifies
    /// two clean stream lifecycles without error, exercising the same structural
    /// multi-turn path that a live handoff would traverse.
    ///
    /// - Note: `GenerationEvent.handoffRequested` maps to `StreamAction.recordHandoff`
    ///   in `GenerationStreamConsumer` and is then handled by `ConversationTurnExecutor`,
    ///   which emits `ConversationEvent.agentHandoff` only when a session record is
    ///   available. The hermetic ``RuntimeScenarioRunner`` runs without a session store,
    ///   so the handoff event would be silently dropped. This two-turn shape exercises
    ///   the same runtime lifecycle path without requiring session state.
    public static let researcherWriterHandoff = RuntimeScenario(
        id: "researcher-writer-handoff",
        displayName: "Researcher → Writer Handoff",
        scenarioDescription: "Two-phase conversation: researcher phase gathers context, writer phase synthesises. Verifies two clean lifecycles without error.",
        userMessages: [
            "Research: what is photosynthesis?",
            "Write: summarise your research findings.",
        ],
        scriptedTurns: [
            .tokens(["Photosynthesis", " converts", " light", " to", " energy", "."]),
            .tokens(["Plants", " use", " sunlight", " to", " make", " food", "."]),
        ],
        expectedSubsequence: [
            .streamStarted, .tokenEmitted, .streamFinished,
            .streamStarted, .tokenEmitted, .streamFinished,
        ]
    )

    // MARK: - P4a: flagship scenario

    /// The centerpiece Glass Box scenario: a multi-turn research conversation
    /// that fills the context window, triggers automatic history compression,
    /// then continues answering coherently from the compressed history.
    ///
    /// The structural assertion it validates is:
    /// ```
    /// contextAssembled         // turn 1 context assembly
    ///   ≺ streamFinished       // turn 1 generation complete
    ///   ≺ contextAssembled     // turn 2 context assembly
    ///   ≺ streamFinished       // turn 2 generation complete
    ///   ≺ historyCompressed    // runtime compresses history before turn 3
    ///   ≺ contextAssembled     // turn 3 assembles from compressed history
    ///   ≺ streamFinished       // turn 3 generation complete
    ///   ≺ contextAssembled     // turn 4 context assembly
    ///   ≺ streamFinished       // turn 4 generation complete
    /// ```
    ///
    /// Pre-turn compression fires when `messageCount >= 4` (2 user + 2
    /// assistant messages from the first two turns). The policy replaces the
    /// stored history with a single synthetic memory record without calling the
    /// inference backend, so the scripted turn sequence is not disrupted.
    ///
    /// This scenario is the scripted (CI) counterpart of the flagship demo
    /// described in Glass Box issue #1531. No real RAG or external calls are
    /// needed — ``FixedCountPreTurnCompressionPolicy`` drives compression
    /// deterministically via message count.
    public static let researchSession = RuntimeScenario(
        id: "self-managing-research-session",
        displayName: "Self-Managing Research Session",
        scenarioDescription: "A 4-turn research conversation that fills the context window after 2 turns, triggers automatic history compression at the start of turn 3 (replacing prior history with a synthetic memory record), then continues coherently from the compressed history. Verifies the full historyCompressed → contextAssembled → streamFinished structural ordering.",
        userMessages: [
            "What is photosynthesis?",
            "How does the light-dependent reaction work?",
            "What role does chlorophyll play?",
            "Summarise everything you've told me so far.",
        ],
        scriptedTurns: [
            .tokens(["Photosynthesis", " converts", " light", " to", " energy", "."]),
            .tokens(["Light", "-dependent", " reactions", " use", " ATP", "."]),
            .tokens(["Chlorophyll", " absorbs", " light", "."]),
            .tokens(["Summary", ": photosynthesis", ", reactions", ", chlorophyll", "."]),
        ],
        // Compression fires before turn 3 (messageCount == 4: 2 user + 2 assistant
        // from turns 1–2), emitting historyCompressed before contextAssembled for
        // that turn. Turns 1, 2, and 4 run without compression.
        expectedSubsequence: [
            .contextAssembled, .streamStarted, .tokenEmitted, .streamFinished,  // turn 1
            .contextAssembled, .streamStarted, .tokenEmitted, .streamFinished,  // turn 2
            .historyCompressed,                                                  // compression fires before turn 3
            .contextAssembled, .streamStarted, .tokenEmitted, .streamFinished,  // turn 3
            .contextAssembled, .streamStarted, .tokenEmitted, .streamFinished,  // turn 4
        ],
        preTurnCompressionPolicy: FixedCountPreTurnCompressionPolicy(compressAfterMessages: 4)
    )
}
#endif
