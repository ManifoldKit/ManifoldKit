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
/// assertion (not scored — never a fabricated pass), and a ``Score`` when it
/// does. These are functions, not ``CheckpointScorer`` conformances: they read
/// fixed schema fields, not an opaque `custom` payload, so the id-dispatch
/// seam ``CheckpointScorer`` provides doesn't apply.
public enum BuiltInCheckpointScorers {

    public static func scoreRequiredContent(_ context: CheckpointEvaluationContext) -> Score? {
        guard let required = context.checkpoint.requiredContent, !required.isEmpty else { return nil }
        let missing = required.filter { !context.output.visibleText.contains($0) }
        if missing.isEmpty {
            return Score(value: .bool(true), metadata: ["assertion": "requiredContent"])
        }
        return Score(
            value: .bool(false),
            explanation: "Missing required content: \(missing.joined(separator: ", "))",
            metadata: ["assertion": "requiredContent"]
        )
    }

    public static func scoreForbiddenContent(_ context: CheckpointEvaluationContext) -> Score? {
        guard let forbidden = context.checkpoint.forbiddenContent, !forbidden.isEmpty else { return nil }
        let present = forbidden.filter { context.output.visibleText.contains($0) }
        if present.isEmpty {
            return Score(value: .bool(true), metadata: ["assertion": "forbiddenContent"])
        }
        return Score(
            value: .bool(false),
            explanation: "Forbidden content present: \(present.joined(separator: ", "))",
            metadata: ["assertion": "forbiddenContent"]
        )
    }

    public static func scoreExpectedEvents(_ context: CheckpointEvaluationContext) -> Score? {
        guard let expectedRaw = context.checkpoint.expectedEvents, !expectedRaw.isEmpty else { return nil }
        let expected = expectedRaw.compactMap(ConversationEventKind.init(rawValue:))
        guard expected.count == expectedRaw.count else {
            return Score(
                value: .unavailable,
                explanation: "One or more expectedEvents entries are not valid ConversationEventKind values: \(expectedRaw)",
                metadata: ["assertion": "expectedEvents"]
            )
        }
        let result = EventSubsequenceChecker.check(context.eventKinds, against: expected)
        return Score(
            value: .bool(result.passed),
            explanation: result.failureReason,
            metadata: ["assertion": "expectedEvents"]
        )
    }

    public static func scoreExpectedToolCalls(_ context: CheckpointEvaluationContext) -> Score? {
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
            return Score(value: .bool(true), metadata: ["assertion": "expectedToolCalls"])
        }
        return Score(
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
    public static func scoreExpectedCompression(_ context: CheckpointEvaluationContext) -> Score? {
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
            return Score(
                value: .bool(false),
                explanation: parts.joined(separator: "; "),
                metadata: ["assertion": "expectedCompression"]
            )
        }
        if !indeterminate.isEmpty {
            return Score(
                value: .unavailable,
                explanation: indeterminate.joined(separator: "; "),
                metadata: ["assertion": "expectedCompression"]
            )
        }
        return Score(value: .bool(true), metadata: ["assertion": "expectedCompression"])
    }

    public static func scoreExpectedContextSlots(_ context: CheckpointEvaluationContext) -> Score? {
        guard let expected = context.checkpoint.expectedContextSlots else { return nil }
        guard let actual = context.lastContextAssembledSlotCount else {
            return Score(
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
            return Score(value: .bool(true), metadata: ["assertion": "expectedContextSlots"])
        }
        return Score(
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
