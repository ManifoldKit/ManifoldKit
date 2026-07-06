import Foundation
import ManifoldInference
import ManifoldRuntime

/// Routes a checkpoint's ``GoldenCheckpoint/custom`` payload to a registered
/// ``EvalJudge``, translating its ``JudgeVerdict`` into a ``Score``.
///
/// A ``CheckpointScorer`` conformance, so it plugs into the exact same
/// `customScorers` id-dispatch seam every other domain scorer uses — there is
/// no separate "judge registry" type. An app registers one
/// `JudgedCheckpointScorer` per judge-scored assertion id it wants to expose,
/// e.g.:
///
/// ```swift
/// let outcome = try await GoldenTaskRunner.run(
///     fixture,
///     customScorers: [
///         JudgedCheckpointScorer(id: "judge:extraction-quality", fixtureID: fixture.id, judge: myJudge)
///     ]
/// )
/// ```
///
/// ## Payload shape
///
/// The `custom` payload under this scorer's `id` must be a JSON object with a
/// `candidate` string, a `rubric` string, and optionally `content` and
/// `reference` strings — decoded into a ``JudgeRequest`` whose `id` is
/// `"\(fixtureID)#\(checkpoint.displayLabel)"` (stable, debuggable cache
/// keys). A payload that doesn't decode to this shape scores `.unavailable`
/// with an explanation, never a crash or a silent pass.
///
/// ## Absence
///
/// Two independent absences, both `.unavailable` (never `.number(0)` or a
/// fabricated pass — the module-wide "absence is never scored as a failure"
/// convention `BuiltInCheckpointScorers` already follows):
/// - No `EvalJudge` wired into this scorer (`judge: nil`) — the checkpoint
///   declared the assertion, but the app hasn't registered a real conformer
///   yet (e.g. wave 2a ships this seam before fireside's `ClaudeCodeJudge`
///   lands — see the module DocC page's liveness note).
/// - The checkpoint declares no `custom` payload for this scorer's `id` at
///   all — distinct from "no scorer registered", which
///   ``GoldenTaskRunner`` already handles at the batch level.
///
/// A judge call that *throws* (subprocess failure, timeout, malformed
/// response) is logged and also surfaces as `.unavailable` with the error in
/// the explanation — a transport failure is not evidence the assertion
/// failed, so it must not silently downgrade to `.bool(false)`.
public struct JudgedCheckpointScorer: CheckpointScorer {
    public let id: String
    private let fixtureID: String
    private let judge: (any EvalJudge)?

    public init(id: String, fixtureID: String, judge: (any EvalJudge)?) {
        self.id = id
        self.fixtureID = fixtureID
        self.judge = judge
    }

    public func score(_ context: CheckpointEvaluationContext) async -> Score {
        guard let judge else {
            return Score(
                value: .unavailable,
                explanation: "no EvalJudge registered for custom key '\(id)'",
                metadata: ["assertion": "custom", "scorerID": id]
            )
        }
        guard let payload = context.checkpoint.custom?[id] else {
            return Score(
                value: .unavailable,
                explanation: "checkpoint '\(context.checkpoint.displayLabel)' declares no custom payload for scorer id '\(id)'",
                metadata: ["assertion": "custom", "scorerID": id]
            )
        }
        guard let request = Self.request(
            from: payload,
            fixtureID: fixtureID,
            checkpointLabel: context.checkpoint.displayLabel
        ) else {
            return Score(
                value: .unavailable,
                explanation: "custom payload for '\(id)' is not a judge-request object (expected string fields: candidate, rubric; optional: content, reference)",
                metadata: ["assertion": "custom", "scorerID": id]
            )
        }

        do {
            let verdict = try await judge.judge(request)
            return Score(
                value: .number(verdict.score),
                explanation: verdict.rationale,
                metadata: [
                    "assertion": "custom",
                    "scorerID": id,
                    "flags": verdict.flags.joined(separator: ","),
                ]
            )
        } catch {
            Log.inference.warning(
                "JudgedCheckpointScorer[\(id, privacy: .public)]: judge failed: \(String(describing: error), privacy: .public)"
            )
            return Score(
                value: .unavailable,
                explanation: "judge failed: \(error)",
                metadata: ["assertion": "custom", "scorerID": id]
            )
        }
    }

    // MARK: - Payload decoding

    private static func request(
        from payload: JSONValue,
        fixtureID: String,
        checkpointLabel: String
    ) -> JudgeRequest? {
        guard case .object(let object) = payload else { return nil }
        guard case .string(let candidate)? = object["candidate"] else { return nil }
        guard case .string(let rubric)? = object["rubric"] else { return nil }

        let content: String
        if case .string(let value)? = object["content"] {
            content = value
        } else {
            content = ""
        }

        let reference: String?
        if case .string(let value)? = object["reference"] {
            reference = value
        } else {
            reference = nil
        }

        return JudgeRequest(
            id: "\(fixtureID)#\(checkpointLabel)",
            content: content,
            candidate: candidate,
            reference: reference,
            rubric: rubric
        )
    }
}
