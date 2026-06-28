import Foundation

/// A read-only projection of one run's output, handed to scorers.
///
/// Deliberately small and eval-native: visible text, reasoning text, the tool
/// calls the model emitted, and the coarse stop reason. A scorer reads only the
/// fields it needs (a similarity scorer reads `visibleText`; a tool-call matcher
/// reads `toolCalls`) — empty fields are honest "this run had none", not stubs.
public struct EvalRunOutput: Sendable {
    /// User-visible assistant text (post-thinking).
    public let visibleText: String
    /// Reasoning/thinking text, if the model produced any.
    public let thinkingText: String
    /// Tool calls the model emitted during the run.
    public let toolCalls: [ToolCall]
    /// Coarse stop classification (`naturalStop` / `maxTokens` / `error` / …),
    /// or empty when the producer did not classify it.
    public let stopReason: String

    public init(
        visibleText: String,
        thinkingText: String = "",
        toolCalls: [ToolCall] = [],
        stopReason: String = ""
    ) {
        self.visibleText = visibleText
        self.thinkingText = thinkingText
        self.toolCalls = toolCalls
        self.stopReason = stopReason
    }
}

/// Scores one run's output against an expectation.
///
/// Expected-vs-actual only — `Expected` is the ground truth the output is judged
/// against (a reference string for similarity, a list of acceptable calls for a
/// tool matcher). Run-level *annotations* that judge a run without an expectation
/// (e.g. generation-hygiene signals) are a separate concern and do **not** belong
/// here as an `Expected == Void` conformance.
public protocol EvalScorer<Expected>: Sendable {
    associatedtype Expected: Sendable
    func score(output: EvalRunOutput, expected: Expected) async -> Score
}
