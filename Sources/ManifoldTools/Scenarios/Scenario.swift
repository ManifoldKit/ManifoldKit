import Foundation

/// Declarative scenario spec. Loaded from the JSON files in
/// `Scenarios/built-in/` and from any `--scenario-file` path passed on the
/// CLI.
///
/// Keeping the configuration declarative (rather than Swift code) means tests
/// can enumerate the full scenario surface without importing any harness
/// types, and new scenarios can be added by dropping a JSON file in the
/// resources directory without recompiling.
public struct Scenario: Codable, Sendable, Equatable {

    public let id: String
    public let description: String
    public let systemPrompt: String
    public let userPrompt: String
    public let requiredTools: [String]
    public let assertions: [Assertion]
    public let backend: BackendSpec

    public struct BackendSpec: Codable, Sendable, Equatable {
        public let kind: String            // "ollama", "mock"
        public let model: String
        public let fallbackModel: String?
        public let temperature: Double?
        public let seed: Int?
        public let topK: Int?
    }

    public struct Assertion: Codable, Sendable, Equatable {
        /// One of:
        /// - `"containsLiteral"` — final-answer text must contain `value` as a substring.
        /// - `"equalsLiteral"` — final-answer text must equal `value` exactly.
        /// - `"containsAll"` — final-answer text must contain every string in `values` as substrings.
        /// - `"containsAny"` — final-answer text must contain at least one string in `values` as a
        ///   substring. Use this for behavioural contracts a correct model can phrase many ways
        ///   (e.g. "acknowledge the size policy") so paraphrase isn't scored as failure — a literal
        ///   `containsAll` over one canonical wording mis-fails every model that paraphrases.
        /// - `"toolInvoked"` — the scenario must have dispatched the tool named `value` at least once.
        ///   This is the honesty gate: a scenario that only asserts `containsLiteral` can silently
        ///   pass when a model hallucinates the expected answer without actually calling the tool.
        /// - `"toolNotInvoked"` — the inverse honesty gate, for scenarios where the *correct*
        ///   behaviour is abstention. When `value` names a tool, that specific tool must never have
        ///   been dispatched (useful for asserting a decoy was never called — the sharpest signal
        ///   in a distractor sweep, since it measures precision directly). When `value` is omitted,
        ///   NO tool at all — real or decoy — may have been dispatched; use this for a scenario whose
        ///   correct answer requires no tool call, so a model that reaches for anything (including a
        ///   distractor it was never asked about) fails loudly instead of the failure being invisible
        ///   behind a passing `containsLiteral`.
        ///
        ///   **`requiredTools` trap (no compiler catches this):** `requiredTools` does double duty
        ///   as both the advertisement filter (`ScenarioRunner` only forwards those tool
        ///   definitions when decoy pressure is off) AND the confusion-matrix expected-positives
        ///   set (`ConformanceScorer`'s TP/FP/FN). A tool named in a `toolNotInvoked` assertion is
        ///   a NEGATIVE and must NEVER also appear in `requiredTools` — putting it there scores the
        ///   scenario's own correct trajectory (never calling it) as a false negative, and a model
        ///   that takes the bait as a clean true positive, which inverts the verdict/F1 relationship
        ///   the scenario exists to measure. (`schema-beats-prose-resistance` is the worked example
        ///   — see #2450.)
        ///
        ///   **Message-wording trap:** never phrase a `toolNotInvoked` message starting with
        ///   `"Scenario requires "` — `ConformanceScorer.expectedToolsFromAssertion` recovers
        ///   backtick-quoted tool names from any assertion message with that prefix (a fallback for
        ///   companion transcripts that omit `requiredTools`), so a message like `"Scenario requires
        ///   `get_current_date` to never be dispatched"` gets the negated tool parsed straight into
        ///   the expected-POSITIVES set — the opposite of what the assertion means. Core is immune
        ///   (it always emits `requiredTools` explicitly, so the recovery fallback never triggers),
        ///   but a companion transcript that omits it is not. `ScenarioRecoveryTests` asserts every
        ///   built-in `toolNotInvoked` message yields nothing from `expectedToolsFromAssertion`.
        /// - `"toolResultContains"` — at least one result for tool `value` must contain every
        ///   string in `values`.
        /// - `"toolResultErrorKind"` — at least one result for tool `value` must have errorKind
        ///   equal to the first entry in `values`.
        public let kind: String
        public let value: String?
        public let values: [String]?
        public let message: String?
    }
}

/// Tool result fragment retained by ``ScenarioRunner`` for assertions.
public struct ToolResultRecord: Equatable, Sendable {
    public let toolName: String
    public let content: String
    public let errorKind: String?

    public init(toolName: String, content: String, errorKind: String?) {
        self.toolName = toolName
        self.content = content
        self.errorKind = errorKind
    }
}

/// Result of evaluating a single assertion against the runner transcript.
public struct AssertionOutcome: Equatable, Sendable {
    public let passed: Bool
    public let message: String

    public init(passed: Bool, message: String) {
        self.passed = passed
        self.message = message
    }
}

/// Evaluates an assertion against the final-answer text the runner observed.
///
/// Pure, synchronous, and free of any side effects so unit tests can drive it
/// directly with canned strings without spinning up a backend.
public enum AssertionEvaluator {

    public static func evaluate(
        _ assertion: Scenario.Assertion,
        finalAnswer: String,
        toolsInvoked: [String] = [],
        toolResults: [ToolResultRecord] = []
    ) -> AssertionOutcome {
        switch assertion.kind {
        case "containsLiteral":
            guard let value = assertion.value else {
                return AssertionOutcome(passed: false, message: "containsLiteral missing 'value'")
            }
            let passed = finalAnswer.contains(value)
            let detail = passed ? "found" : "missing"
            let label = assertion.message ?? "contains '\(value)'"
            return AssertionOutcome(passed: passed, message: "\(label) — \(detail)")

        case "equalsLiteral":
            guard let value = assertion.value else {
                return AssertionOutcome(passed: false, message: "equalsLiteral missing 'value'")
            }
            let passed = finalAnswer == value
            let label = assertion.message ?? "equals '\(value)'"
            return AssertionOutcome(passed: passed, message: label)

        case "containsAll":
            guard let values = assertion.values, !values.isEmpty else {
                return AssertionOutcome(passed: false, message: "containsAll missing 'values'")
            }
            let passed = values.allSatisfy { finalAnswer.contains($0) }
            let label = assertion.message ?? "contains all of \(values)"
            return AssertionOutcome(passed: passed, message: label)

        case "containsAny":
            guard let values = assertion.values, !values.isEmpty else {
                return AssertionOutcome(passed: false, message: "containsAny missing 'values'")
            }
            let passed = values.contains { finalAnswer.contains($0) }
            let detail = passed ? "found" : "none present"
            let label = assertion.message ?? "contains any of \(values)"
            return AssertionOutcome(passed: passed, message: "\(label) — \(detail)")

        case "toolInvoked":
            guard let name = assertion.value else {
                return AssertionOutcome(passed: false, message: "toolInvoked missing 'value'")
            }
            let passed = toolsInvoked.contains(name)
            let detail = passed ? "dispatched" : "never dispatched — final answer may be hallucinated"
            let label = assertion.message ?? "tool '\(name)' invoked"
            return AssertionOutcome(passed: passed, message: "\(label) — \(detail)")

        case "toolNotInvoked":
            if let name = assertion.value {
                let passed = !toolsInvoked.contains(name)
                let detail = passed ? "correctly withheld" : "dispatched — should have been withheld"
                let label = assertion.message ?? "tool '\(name)' not invoked"
                return AssertionOutcome(passed: passed, message: "\(label) — \(detail)")
            } else {
                let passed = toolsInvoked.isEmpty
                let detail = passed ? "no tool dispatched" : "dispatched \(toolsInvoked) — expected total abstention"
                let label = assertion.message ?? "no tool invoked"
                return AssertionOutcome(passed: passed, message: "\(label) — \(detail)")
            }

        case "toolResultContains":
            guard let name = assertion.value else {
                return AssertionOutcome(passed: false, message: "toolResultContains missing 'value'")
            }
            guard let values = assertion.values, !values.isEmpty else {
                return AssertionOutcome(passed: false, message: "toolResultContains missing 'values'")
            }
            let matchingResults = toolResults.filter { $0.toolName == name }
            let passed = matchingResults.contains { result in
                values.allSatisfy { result.content.contains($0) }
            }
            let detail = passed ? "found in tool result" : "missing from tool results"
            let label = assertion.message ?? "tool '\(name)' result contains \(values)"
            return AssertionOutcome(passed: passed, message: "\(label) — \(detail)")

        case "toolResultErrorKind":
            guard let name = assertion.value else {
                return AssertionOutcome(passed: false, message: "toolResultErrorKind missing 'value'")
            }
            guard let expected = assertion.values?.first else {
                return AssertionOutcome(passed: false, message: "toolResultErrorKind missing first 'values' entry")
            }
            let passed = toolResults.contains { $0.toolName == name && $0.errorKind == expected }
            let detail = passed ? "observed" : "not observed"
            let label = assertion.message ?? "tool '\(name)' errorKind == \(expected)"
            return AssertionOutcome(passed: passed, message: "\(label) — \(detail)")

        default:
            return AssertionOutcome(
                passed: false,
                message: "unknown assertion kind '\(assertion.kind)'"
            )
        }
    }
}
