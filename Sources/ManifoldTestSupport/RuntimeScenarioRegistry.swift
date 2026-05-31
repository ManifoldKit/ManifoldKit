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
}
#endif
