import Foundation
import ManifoldInference
import ManifoldRuntime

/// Grades executed checkpoint output with an app-supplied runtime candidate extractor.
///
/// The fixture supplies `rubric`, a finite `minScore` in 0...1, and optional
/// grounding `content` and `reference` strings. The candidate comes exclusively
/// from `candidateExtractor`, which reads the context's output or typed snapshot.
/// Throw when required state is missing; never substitute fixture data or an
/// empty string for missing evidence. An actually observed empty output may be
/// returned and graded normally.
///
/// Missing evidence, invalid declarations and judge errors are `.unavailable`,
/// making a required assertion indeterminate. A valid measured judge score is
/// reduced to `.bool` against the explicit bar. For offline grading of supplied
/// data, construct a `JudgeRequest` and call `EvalJudge` directly instead.
public struct JudgedCheckpointScorer: CheckpointScorer {
    public let id: String
    private let judge: (any EvalJudge)?
    private let candidateExtractor: @Sendable (CheckpointEvaluationContext) throws -> String

    public init(
        id: String,
        judge: (any EvalJudge)?,
        candidateExtractor: @escaping @Sendable (CheckpointEvaluationContext) throws -> String
    ) {
        self.id = id
        self.judge = judge
        self.candidateExtractor = candidateExtractor
    }

    public func score(_ context: CheckpointEvaluationContext) async -> EvalScore {
        guard let judge else {
            return unavailable("judge-absent", "no EvalJudge registered for custom key '\(id)'")
        }
        guard let payload = context.checkpoint.custom?[id] else {
            return unavailable("no-payload", "checkpoint declares no custom payload for scorer id '\(id)'")
        }
        guard case .object(let object) = payload, case .string(let rubric)? = object["rubric"] else {
            return unavailable("invalid-payload", "expected a judge-request object with rubric (string), minScore (number), and optional content/reference (strings)")
        }
        guard object["candidate"] == nil else {
            return unavailable("fixture-candidate", "remove fixture candidate; candidateExtractor must read executed output or state")
        }
        guard case .number(let minScore)? = object["minScore"], minScore.isFinite,
              (0...1).contains(minScore) else {
            return unavailable("invalid-minScore", "minScore must be a finite number in 0...1")
        }
        let content: String
        if let value = object["content"] {
            guard case .string(let text) = value else {
                return unavailable("invalid-payload", "content must be a string when supplied")
            }
            content = text
        } else {
            content = ""
        }
        let reference: String?
        if let value = object["reference"] {
            guard case .string(let text) = value else {
                return unavailable("invalid-payload", "reference must be a string when supplied")
            }
            reference = text
        } else {
            reference = nil
        }

        let candidate: String
        do {
            candidate = try candidateExtractor(context)
        } catch {
            Log.inference.warning("JudgedCheckpointScorer[\(id, privacy: .public)]: candidate extraction failed: \(String(describing: error), privacy: .public)")
            return unavailable("candidate-extraction-error", "candidate extraction failed: \(error)")
        }
        let request = JudgeRequest(
            id: "\(context.fixtureID)#\(context.checkpoint.displayLabel)",
            content: content,
            candidate: candidate,
            reference: reference,
            rubric: rubric
        )
        do {
            let verdict = try await judge.judge(request)
            guard verdict.score.isFinite, (0...1).contains(verdict.score) else {
                return unavailable("invalid-judge-score", "judge score must be a finite number in 0...1")
            }
            return EvalScore(
                value: .bool(verdict.score >= minScore),
                explanation: "judge score \(Self.format(verdict.score)) vs minScore \(Self.format(minScore)): \(verdict.rationale)",
                metadata: [
                    "assertion": "custom", "scorerID": id,
                    "judgeScore": Self.format(verdict.score), "minScore": Self.format(minScore),
                    "flags": verdict.flags.joined(separator: ","),
                ]
            )
        } catch {
            Log.inference.warning("JudgedCheckpointScorer[\(id, privacy: .public)]: judge failed: \(String(describing: error), privacy: .public)")
            return unavailable("judge-error", "judge failed: \(error)")
        }
    }

    private func unavailable(_ reason: String, _ explanation: String) -> EvalScore {
        EvalScore(
            value: .unavailable, explanation: explanation,
            metadata: ["assertion": "custom", "scorerID": id, "reason": reason]
        )
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
