import Foundation
import ManifoldInference

/// Argument-level tool-call matcher modelled on the Berkeley Function Calling
/// Leaderboard (BFCL) AST check.
///
/// `ConformanceScorer` answers *which tools were called* (name-only, set-based).
/// It cannot tell a `calc(a: 17, b: 4)` from a `calc(a: 99, b: 0)` — both score a
/// true positive on the `calc` name. The whole point of this matcher is the axis
/// the name-only scorer is blind to: did the model call the **right function with
/// the right argument values**.
///
/// The semantics mirror BFCL's non-executable AST track for the `simple`
/// category, driven by the `possible_answer` ground truth:
///
/// 1. **name** — the emitted call's tool name equals the ground-truth function.
/// 2. **values** — every supplied argument's value is one of the ground truth's
///    accepted values for that parameter (BFCL pins a *list* of acceptable values
///    per parameter, e.g. `unit: ["units", ""]`, to tolerate legitimate variation).
/// 3. **no hallucinated params** — the model supplied no parameter the ground
///    truth doesn't enumerate.
/// 4. **no missing params** — every parameter the ground truth treats as required
///    (its accepted-value list does not include the empty string `""`, BFCL's
///    "optional / may be omitted" marker) is present.
///
/// Numeric comparison is cross-type tolerant: a JSON `10` (decoded as
/// ``JSONSchemaValue/integer(_:)``) matches a ground-truth `10.0`
/// (``JSONSchemaValue/number(_:)``) and vice versa, because models legitimately
/// emit either spelling for the same value.
///
/// Deliberately *not* reimplemented here (deferred to the one-time `bfcl-eval`
/// cross-check the spike proposes): BFCL's full type-coercion table, nested-object
/// structural matching beyond value equality, and the executable / multi-turn /
/// agentic tracks. The `simple` category — flat scalar arguments, one expected
/// call — is where the argument-correctness signal is highest for the least
/// matcher surface.
public enum ASTMatcher {

    /// Why a single call failed to match a single ground-truth alternative.
    ///
    /// Carried on a non-match so a sweep can report *how* a model got the
    /// arguments wrong (wrong value vs. missing vs. hallucinated), not just that
    /// it did. Pure data so tests can assert on the exact failure.
    public enum Failure: Equatable, Sendable, CustomStringConvertible {
        /// The tool name did not match the ground-truth function name.
        case nameMismatch(expected: String, actual: String)
        /// A parameter the ground truth requires was not supplied.
        case missingRequiredParam(String)
        /// The model supplied a parameter the ground truth does not enumerate.
        case hallucinatedParam(String)
        /// A supplied parameter's value is not among the accepted values.
        case valueNotAllowed(param: String, actual: String, allowed: [String])
        /// The call's `arguments` string was not decodable as a JSON object.
        case argumentsUnparseable(String)

        public var description: String {
            switch self {
            case .nameMismatch(let expected, let actual):
                return "name: expected '\(expected)', got '\(actual)'"
            case .missingRequiredParam(let p):
                return "missing required param '\(p)'"
            case .hallucinatedParam(let p):
                return "hallucinated param '\(p)'"
            case .valueNotAllowed(let param, let actual, let allowed):
                return "param '\(param)' = \(actual), not in \(allowed)"
            case .argumentsUnparseable(let raw):
                return "arguments not JSON object: \(raw)"
            }
        }
    }

    /// Outcome of matching one emitted call against one ground-truth alternative.
    public struct MatchResult: Equatable, Sendable {
        public let matched: Bool
        /// Empty when ``matched`` is `true`; otherwise every reason the match failed.
        public let failures: [Failure]

        public init(matched: Bool, failures: [Failure]) {
            self.matched = matched
            self.failures = failures
        }

        static let ok = MatchResult(matched: true, failures: [])
        static func failed(_ failures: [Failure]) -> MatchResult {
            MatchResult(matched: false, failures: failures)
        }
    }

    /// Matches a single emitted ``ToolCall`` against a single ground-truth
    /// alternative. Reports *all* failures, not just the first, so a sweep can
    /// surface every way the arguments diverged in one pass.
    public static func match(call: ToolCall, against expected: BFCLExpectedCall) -> MatchResult {
        var failures: [Failure] = []

        // 1. name
        if call.toolName != expected.functionName {
            failures.append(.nameMismatch(expected: expected.functionName, actual: call.toolName))
            // A name mismatch makes per-argument diagnostics misleading (the
            // argument schemas belong to different functions), so stop here.
            return .failed(failures)
        }

        // Parse the model's JSON argument payload. An unparseable payload is a
        // hard fail — we cannot reason about arguments we can't decode.
        guard let actualArgs = Self.decodeArguments(call.arguments) else {
            failures.append(.argumentsUnparseable(call.arguments))
            return .failed(failures)
        }

        // 3. no hallucinated params — every supplied param must be enumerated by
        // the ground truth.
        for suppliedParam in actualArgs.keys where expected.acceptedValues[suppliedParam] == nil {
            failures.append(.hallucinatedParam(suppliedParam))
        }

        for (param, allowed) in expected.acceptedValues {
            if let actualValue = actualArgs[param] {
                // 2. value must be one of the accepted values.
                let isAllowed = allowed.contains { Self.valuesEqual(actualValue, $0) }
                if !isAllowed {
                    failures.append(.valueNotAllowed(
                        param: param,
                        actual: Self.describe(actualValue),
                        allowed: allowed.map(Self.describe)
                    ))
                }
            } else if expected.requiredParams.contains(param) {
                // 4. a required param (accepted list lacks the "" optional marker)
                // was omitted.
                failures.append(.missingRequiredParam(param))
            }
            // Omitted + optional (allowed contains "") → fine, no failure.
        }

        return failures.isEmpty ? .ok : .failed(failures)
    }

    /// Scores a model's full set of emitted calls for one BFCL case against its
    /// ground-truth alternatives.
    ///
    /// BFCL `simple` expects exactly one function call; a case is *correct* when
    /// at least one emitted call matches at least one ground-truth alternative.
    /// The best (fewest-failure) attempt's diagnostics are surfaced so a miss is
    /// explainable.
    public static func scoreCase(
        emittedCalls: [ToolCall],
        groundTruth: [BFCLExpectedCall]
    ) -> CaseScore {
        guard !emittedCalls.isEmpty else {
            return CaseScore(matched: false, bestFailures: [.missingRequiredParam("<no tool call emitted>")])
        }

        // Rank non-matching attempts so the surfaced diagnostics describe the
        // *closest* miss. The key is `(nameMismatched, failureCount)` compared
        // lexicographically: an attempt that called the right function with wrong
        // arguments (0, …) always ranks ahead of one that called the wrong
        // function (1, …), and within each tier fewer failures rank higher. A
        // wrong-value miss is far more actionable than "you called the wrong tool".
        var best: (key: (Int, Int), failures: [Failure])?

        for call in emittedCalls {
            for alternative in groundTruth {
                let result = match(call: call, against: alternative)
                if result.matched {
                    return CaseScore(matched: true, bestFailures: [])
                }
                let nameMismatched = result.failures.contains {
                    if case .nameMismatch = $0 { return true }
                    return false
                }
                let key = (nameMismatched ? 1 : 0, result.failures.count)
                if let current = best {
                    if key < current.key { best = (key, result.failures) }
                } else {
                    best = (key, result.failures)
                }
            }
        }
        return CaseScore(matched: false, bestFailures: best?.failures ?? [])
    }

    /// Per-case argument-level outcome.
    public struct CaseScore: Equatable, Sendable {
        /// `true` when some emitted call matched some ground-truth alternative.
        public let matched: Bool
        /// Diagnostics from the closest (fewest-failure) non-matching attempt.
        public let bestFailures: [Failure]

        public init(matched: Bool, bestFailures: [Failure]) {
            self.matched = matched
            self.bestFailures = bestFailures
        }
    }

    // MARK: - Value comparison

    /// Decodes a tool call's JSON `arguments` string into a parameter map.
    /// Returns `nil` when the payload is not a JSON object.
    static func decodeArguments(_ raw: String) -> [String: JSONSchemaValue]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: JSONSchemaValue].self, from: data)
    }

    /// Value equality with cross-type numeric tolerance.
    ///
    /// Models emit `10` and `10.0` interchangeably for the same value, and JSON
    /// decoding splits those into ``JSONSchemaValue/integer(_:)`` vs
    /// ``JSONSchemaValue/number(_:)`` — so the synthesized `==` would reject a
    /// correct answer. We bridge integer/number numerically and otherwise fall
    /// back to structural equality.
    static func valuesEqual(_ a: JSONSchemaValue, _ b: JSONSchemaValue) -> Bool {
        switch (a, b) {
        case let (.integer(x), .integer(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.integer(x), .number(y)): return Double(x) == y
        case let (.number(x), .integer(y)): return x == Double(y)
        case let (.string(x), .string(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        case let (.array(x), .array(y)):
            return x.count == y.count && zip(x, y).allSatisfy { valuesEqual($0, $1) }
        case let (.object(x), .object(y)):
            return x.keys == y.keys && x.allSatisfy { key, value in
                guard let other = y[key] else { return false }
                return valuesEqual(value, other)
            }
        default:
            return false
        }
    }

    /// Compact human-readable rendering of a value for failure diagnostics.
    static func describe(_ value: JSONSchemaValue) -> String {
        switch value {
        case .string(let s): return "\"\(s)\""
        case .integer(let i): return String(i)
        case .number(let n): return String(n)
        case .bool(let b): return String(b)
        case .null: return "null"
        case .array(let a): return "[" + a.map(describe).joined(separator: ", ") + "]"
        case .object(let o):
            return "{" + o.sorted { $0.key < $1.key }.map { "\($0.key): \(describe($0.value))" }.joined(separator: ", ") + "}"
        }
    }
}
