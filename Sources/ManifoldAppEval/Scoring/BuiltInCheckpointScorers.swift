import Foundation
import ManifoldInference
import ManifoldRuntime

/// Stable keys for the built-in assertion kinds' entries in
/// ``GoldenTaskRunner/CheckpointResult/scores``.
public enum BuiltInCheckpointAssertion: String, Sendable, CaseIterable {
    case requiredContent
    case forbiddenContent
    case expectedEvents
    case expectedToolCalls
    case expectedCompression
    case expectedContextSlots
}

/// Plain-function scorers for every built-in ``GoldenCheckpoint`` assertion
/// kind. Each returns `nil` when the checkpoint doesn't declare that
/// assertion (not scored — never a fabricated pass), and a ``EvalScore`` when it
/// does. These are functions, not ``CheckpointScorer`` conformances: they read
/// fixed schema fields, not an opaque `custom` payload, so the id-dispatch
/// seam ``CheckpointScorer`` provides doesn't apply.
public enum BuiltInCheckpointScorers {

    /// Matching options for the content-presence scorers
    /// (``scoreRequiredContent(_:options:)``/``scoreForbiddenContent(_:options:)``).
    ///
    /// Defaults reproduce the scorers' original, unparameterized behavior
    /// exactly — cumulative transcript, case-sensitive substring match — so
    /// every option here is opt-in and existing callers (including the
    /// zero-arg call sites in ``GoldenTaskRunner``) see no behavior change.
    ///
    /// Added for #2201: apps whose checkpoint semantics differ from the
    /// harness's default (e.g. Fireside scores the current scene only, case
    /// insensitively) can now parameterize the built-ins instead of forking
    /// them.
    public struct ContentMatchOptions: Sendable {
        /// Which slice of the transcript a content scorer reads.
        public enum Scope: Sendable {
            /// Every assistant message produced up to and including this
            /// checkpoint's turn. Default — matches the scorers' original
            /// behavior.
            case cumulative
            /// Only the assistant message(s) produced by this checkpoint's
            /// own turn (``CheckpointEvaluationContext/latestTurnVisibleText``).
            case latestTurn
        }

        /// Case-insensitive substring matching. `false` (case-sensitive)
        /// reproduces the scorers' original behavior.
        public var caseInsensitive: Bool
        /// Which slice of the transcript to match against. `.cumulative`
        /// reproduces the scorers' original behavior.
        public var scope: Scope

        public init(caseInsensitive: Bool = false, scope: Scope = .cumulative) {
            self.caseInsensitive = caseInsensitive
            self.scope = scope
        }
    }

    public static func scoreRequiredContent(
        _ context: CheckpointEvaluationContext,
        options: ContentMatchOptions = ContentMatchOptions()
    ) -> EvalScore? {
        guard let required = context.checkpoint.requiredContent, !required.isEmpty else { return nil }
        let haystack = matchText(context, options: options)
        let missing = required.filter { !contains(haystack, needle: $0, options: options) }
        if missing.isEmpty {
            return EvalScore(value: .bool(true), metadata: ["assertion": "requiredContent"])
        }
        return EvalScore(
            value: .bool(false),
            explanation: "Missing required content: \(missing.joined(separator: ", "))",
            metadata: ["assertion": "requiredContent"]
        )
    }

    public static func scoreForbiddenContent(
        _ context: CheckpointEvaluationContext,
        options: ContentMatchOptions = ContentMatchOptions()
    ) -> EvalScore? {
        guard let forbidden = context.checkpoint.forbiddenContent, !forbidden.isEmpty else { return nil }
        let haystack = matchText(context, options: options)
        let present = forbidden.filter { contains(haystack, needle: $0, options: options) }
        if present.isEmpty {
            return EvalScore(value: .bool(true), metadata: ["assertion": "forbiddenContent"])
        }
        return EvalScore(
            value: .bool(false),
            explanation: "Forbidden content present: \(present.joined(separator: ", "))",
            metadata: ["assertion": "forbiddenContent"]
        )
    }

    /// Selects the transcript slice ``ContentMatchOptions/scope`` asks for.
    private static func matchText(_ context: CheckpointEvaluationContext, options: ContentMatchOptions) -> String {
        switch options.scope {
        case .cumulative: return context.output.visibleText
        case .latestTurn: return context.latestTurnVisibleText
        }
    }

    /// Substring containment honoring ``ContentMatchOptions/caseInsensitive``.
    private static func contains(_ haystack: String, needle: String, options: ContentMatchOptions) -> Bool {
        guard options.caseInsensitive else { return haystack.contains(needle) }
        return haystack.range(of: needle, options: .caseInsensitive) != nil
    }

    public static func scoreExpectedEvents(_ context: CheckpointEvaluationContext) -> EvalScore? {
        guard let expectedRaw = context.checkpoint.expectedEvents, !expectedRaw.isEmpty else { return nil }
        let expected = expectedRaw.compactMap(ConversationEventKind.init(rawValue:))
        guard expected.count == expectedRaw.count else {
            return EvalScore(
                value: .unavailable,
                explanation: "One or more expectedEvents entries are not valid ConversationEventKind values: \(expectedRaw)",
                metadata: ["assertion": "expectedEvents"]
            )
        }
        let result = EventSubsequenceChecker.check(context.eventKinds, against: expected)
        return EvalScore(
            value: .bool(result.passed),
            explanation: result.failureReason,
            metadata: ["assertion": "expectedEvents"]
        )
    }

    public static func scoreExpectedToolCalls(_ context: CheckpointEvaluationContext) -> EvalScore? {
        guard let expected = context.checkpoint.expectedToolCalls, !expected.isEmpty else { return nil }
        var failures: [String] = []
        for expectation in expected {
            guard let call = context.output.toolCalls.first(where: { $0.toolName == expectation.name }) else {
                failures.append("no call to '\(expectation.name)'")
                continue
            }
            guard let argumentsContain = expectation.argumentsContain, !argumentsContain.isEmpty else { continue }
            guard let decodedArgs = decodeArguments(call.arguments) else {
                failures.append("call to '\(expectation.name)' has non-object arguments: \(call.arguments)")
                continue
            }
            for (key, expectedSubstring) in argumentsContain.sorted(by: { $0.key < $1.key }) {
                guard let actualValue = decodedArgs[key] else {
                    failures.append("call to '\(expectation.name)' is missing argument '\(key)'")
                    continue
                }
                if !actualValue.contains(expectedSubstring) {
                    failures.append("call to '\(expectation.name)' argument '\(key)' = '\(actualValue)' does not contain '\(expectedSubstring)'")
                }
            }
        }
        if failures.isEmpty {
            return EvalScore(value: .bool(true), metadata: ["assertion": "expectedToolCalls"])
        }
        return EvalScore(
            value: .bool(false),
            explanation: failures.joined(separator: "; "),
            metadata: ["assertion": "expectedToolCalls"]
        )
    }

    /// Verdict precedence: any accrued failure wins outright (a proven
    /// failure must never be masked by another sub-assertion's absence);
    /// otherwise any indeterminate sub-assertion yields `.unavailable`
    /// (a pass can't be claimed while part of the declaration was never
    /// measured); a full pass requires every declared sub-assertion to have
    /// measured and held.
    public static func scoreExpectedCompression(_ context: CheckpointEvaluationContext) -> EvalScore? {
        guard let expected = context.checkpoint.expectedCompression else { return nil }
        var failures: [String] = []
        var indeterminate: [String] = []
        if let maxRetained = expected.maxRetainedMessages, context.producedMessageCount > maxRetained {
            failures.append("retained \(context.producedMessageCount) messages, expected at most \(maxRetained)")
        }
        if let minInserted = expected.minInsertedRecords {
            if let actualInserted = context.lastCompressionInsertedRecordCount {
                if actualInserted < minInserted {
                    failures.append("historyCompressed inserted \(actualInserted) records, expected at least \(minInserted)")
                }
            } else {
                indeterminate.append("minInsertedRecords declared but no historyCompressed event has fired yet")
            }
        }
        if !failures.isEmpty {
            var parts = failures
            if !indeterminate.isEmpty {
                parts.append("also indeterminate: \(indeterminate.joined(separator: "; "))")
            }
            return EvalScore(
                value: .bool(false),
                explanation: parts.joined(separator: "; "),
                metadata: ["assertion": "expectedCompression"]
            )
        }
        if !indeterminate.isEmpty {
            return EvalScore(
                value: .unavailable,
                explanation: indeterminate.joined(separator: "; "),
                metadata: ["assertion": "expectedCompression"]
            )
        }
        return EvalScore(value: .bool(true), metadata: ["assertion": "expectedCompression"])
    }

    public static func scoreExpectedContextSlots(_ context: CheckpointEvaluationContext) -> EvalScore? {
        guard let expected = context.checkpoint.expectedContextSlots else { return nil }
        guard let actual = context.lastContextAssembledSlotCount else {
            return EvalScore(
                value: .unavailable,
                explanation: "expectedContextSlots declared but no contextAssembled event has fired yet",
                metadata: ["assertion": "expectedContextSlots"]
            )
        }
        var failures: [String] = []
        if let minSlots = expected.minSlots, actual < minSlots {
            failures.append("assembled \(actual) slots, expected at least \(minSlots)")
        }
        if let maxSlots = expected.maxSlots, actual > maxSlots {
            failures.append("assembled \(actual) slots, expected at most \(maxSlots)")
        }
        if failures.isEmpty {
            return EvalScore(value: .bool(true), metadata: ["assertion": "expectedContextSlots"])
        }
        return EvalScore(
            value: .bool(false),
            explanation: failures.joined(separator: "; "),
            metadata: ["assertion": "expectedContextSlots"]
        )
    }

    /// Decodes a ``ToolCall/arguments`` JSON string into a flat
    /// `[String: String]` for substring comparison. Non-string values are
    /// stringified via `String(describing:)`; a non-object top level (or
    /// undecodable JSON) returns `nil`.
    private static func decodeArguments(_ raw: String) -> [String: String]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let dict = jsonObject as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (key, value) in dict {
            if let stringValue = value as? String {
                result[key] = stringValue
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }
}
