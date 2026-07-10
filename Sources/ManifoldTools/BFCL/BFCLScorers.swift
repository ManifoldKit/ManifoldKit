import Foundation
import ManifoldInference

/// Argument-level structural scorer for one BFCL case: does some emitted call
/// match some ground-truth alternative on function name *and* arguments?
///
/// A genuine ``EvalScorer`` conformance, not a veneer — the AST-match logic
/// (``ASTMatcher/scoreCase(emittedCalls:groundTruth:)``) is the score function,
/// and ``BFCLRunner`` drives the run through this type's `EvalScore` output rather
/// than reading a bool out of band.
public struct BFCLASTScorer: EvalScorer {
    public typealias Expected = [BFCLExpectedCall]

    public init() {}

    public func score(output: EvalRunOutput, expected: [BFCLExpectedCall]) async -> EvalScore {
        let result = ASTMatcher.scoreCase(emittedCalls: output.toolCalls, groundTruth: expected)
        return EvalScore(
            value: .bool(result.matched),
            explanation: result.matched ? nil : result.bestFailures.first.map { "\($0)" },
            metadata: ["scorer": "bfcl-ast"]
        )
    }
}

/// Name-only scorer: did the model call the right *function*, regardless of
/// whether the arguments are correct? This is the weaker signal a name-only
/// conformance scorer credits; contrasting it with ``BFCLASTScorer`` is the whole
/// point of the BFCL AST track (the gap = right tool, wrong arguments).
public struct BFCLNameOnlyScorer: EvalScorer {
    public typealias Expected = [BFCLExpectedCall]

    public init() {}

    public func score(output: EvalRunOutput, expected: [BFCLExpectedCall]) async -> EvalScore {
        let nameMatched = output.toolCalls.contains { call in
            expected.contains { $0.functionName == call.toolName }
        }
        return EvalScore(value: .bool(nameMatched), metadata: ["scorer": "bfcl-name-only"])
    }
}
