import Foundation
import ManifoldInference
import ManifoldRuntime

/// The shared scenario registry — the single source of truth for both the
/// CI test matrix and the demo picker.
///
/// Add new scenarios here as static properties; they are automatically
/// included in ``all`` and therefore in both the test matrix and the demo UI.
package enum RuntimeScenarioRegistry {

    /// All registered scenarios. Tests enumerate this to build the CI matrix;
    /// the demo picker reads it to populate its scenario list.
    package static let all: [RuntimeScenario] = [
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
        // Glass Box turn-kind coverage (tool / cancel / regenerate):
        .toolRoundTrip,
        .cancelMidStream,
        .regenerateTurn,
    ]
}

// MARK: - Built-in scenarios

extension RuntimeScenario {

    /// Simplest possible scenario: single turn, plain token stream.
    package static let basicTokenStream = RuntimeScenario(
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
    package static let kvCacheReuseAdvisory = RuntimeScenario(
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

    /// Verifies that a `throttleDiagnostic` advisory does not abort generation.
    package static let diagnosticThrottleAdvisory = RuntimeScenario(
        id: "diagnostic-throttle-advisory",
        displayName: "Diagnostic Throttle Advisory",
        scenarioDescription: "Backend emits a throttleDiagnostic event before tokens. Verifies the runtime treats the advisory as informational.",
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
    package static let multiTurnConversation = RuntimeScenario(
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
    package static let swapTheBrain = RuntimeScenario(
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
    package static let midStreamErrorRecovery = RuntimeScenario(
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
    package static let researcherWriterHandoff = RuntimeScenario(
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
    package static let researchSession = RuntimeScenario(
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

    // MARK: - Glass Box turn-kind scenarios

    /// A single user turn whose model emits a tool call instead of a direct
    /// answer. The runner registers an ``AppEvalEchoTool`` so the dispatch
    /// loop routes the call, auto-approves it (the tool needs no approval), runs
    /// it, then re-prompts the backend for the visible answer.
    ///
    /// Verifies the full runtime tool trio in order:
    /// `toolCallRequested ≺ toolCallApproved ≺ toolCallCompleted`, bracketed by
    /// one stream lifecycle that spans both backend rounds. `.toolCallApproved`
    /// is the case wired by the Glass Box event-wiring slice (#1207).
    package static let toolRoundTrip = RuntimeScenario(
        id: "tool-roundtrip",
        displayName: "Tool Round Trip",
        scenarioDescription: "One user turn where the model requests a tool, the runtime auto-approves and executes it via the registry, then re-prompts for the final answer. Verifies toolCallRequested → toolCallApproved → toolCallCompleted ordering within a single stream lifecycle.",
        turns: [
            .send("Use the echo tool.")
        ],
        scriptedTurns: [
            // Round 1: model requests the tool (no visible text).
            .toolCall(ToolCall(id: "echo-1", toolName: "echo", arguments: "{}")),
            // Round 2: final answer after the tool result is fed back.
            .tokens(["Echoed", " result", "."]),
        ],
        expectedSubsequence: [
            .streamStarted,
            .toolCallRequested,
            .toolCallApproved,
            .toolCallCompleted,
            .tokenEmitted,
            .streamFinished,
        ],
        toolExecutors: [
            AppEvalEchoTool(toolName: "echo", response: "Echo: hello")
        ]
    )

    /// A single turn cancelled mid-stream after the first token. The runner
    /// drives the scripted backend's emission gate so the cancel lands before
    /// the stream's natural completion, producing a terminal
    /// `streamFinished(reason: .cancelled)`.
    ///
    /// The structural subsequence ends at `.streamFinished`; the
    /// `.cancelled` reason is asserted directly against the trace in the
    /// dedicated per-scenario test (the kind-level subsequence cannot encode the
    /// finish reason).
    package static let cancelMidStream = RuntimeScenario(
        id: "cancel-midstream",
        displayName: "Cancel Mid-Stream",
        scenarioDescription: "A single turn cancelled after the first streamed token. Verifies the runtime terminates the turn with streamFinished(.cancelled) rather than running to natural completion.",
        turns: [
            RuntimeScenario.ScenarioTurn(
                action: .send(text: "Cancel me partway through."),
                cancelAfterTokens: 1,
                // One char per flush so the first token is its own .tokenEmitted.
                streamingBatchCharacterLimit: 1
            )
        ],
        scriptedTurns: [
            // More tokens than we release: the gate parks the rest until cancel.
            .tokens(["Hello", " world", " this", " keeps", " going"])
        ],
        expectedSubsequence: [
            .streamStarted,
            .tokenEmitted,
            .streamFinished,
        ]
    )

    /// A send turn followed by a regenerate turn. Regenerate deletes the prior
    /// assistant message (emitting `.messageRemoved`) before driving a fresh
    /// generation, so the trace shows the regenerate signature:
    /// `messageRemoved ≺ streamStarted ≺ streamFinished` after the first turn's
    /// own lifecycle.
    package static let regenerateTurn = RuntimeScenario(
        id: "regenerate-turn",
        displayName: "Regenerate Turn",
        scenarioDescription: "A send turn then a regenerate turn. Verifies regenerate removes the prior assistant message (messageRemoved) and drives a fresh streamStarted → streamFinished lifecycle.",
        turns: [
            .send("What is the capital of France?"),
            .regenerate,
        ],
        scriptedTurns: [
            .tokens(["Paris", "."]),
            .tokens(["It", " is", " Paris", "."]),
        ],
        expectedSubsequence: [
            // Turn 1: send
            .streamStarted, .tokenEmitted, .streamFinished,
            // Turn 2: regenerate removes the prior assistant reply, then a fresh
            // lifecycle.
            .messageRemoved, .streamStarted, .tokenEmitted, .streamFinished,
        ]
    )
}
