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
