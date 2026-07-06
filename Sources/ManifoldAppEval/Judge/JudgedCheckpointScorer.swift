import Foundation
import ManifoldInference
import ManifoldRuntime

/// Routes a checkpoint's ``GoldenCheckpoint/custom`` payload to a registered
/// ``EvalJudge``, reducing its ``JudgeVerdict`` to a pass/fail ``Score``
/// against the payload's declared `minScore` bar.
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
///         JudgedCheckpointScorer(id: "judge:extraction-quality", judge: myJudge)
///     ]
/// )
/// ```
///
/// First production conformer: fireside's `ClaudeCodeJudge` (fireside PR
/// #901, drafted against this branch); both PRs ready only after the next MK
/// release — protocol and conformer land in the same release train.
///
/// ## Payload shape
///
/// The `custom` payload under this scorer's `id` must be a JSON object with a
/// `candidate` string, a `rubric` string, and a **required `minScore` number
/// in 0.0–1.0** (the pass bar), plus optional `content` and `reference`
/// strings. The verdict reduces to `.bool(verdict.score >= minScore)` — the
/// raw judge score, the bar, the rationale, and the flags all stay visible in
/// the score's explanation/metadata, so the rendered report still shows the
/// number, but the number itself never carries verdict weight
/// (``AppEvalVerdict/aggregate(_:)`` only fails on `.bool(false)`; an
/// un-reduced `.number` would make the judge assertion verdict-inert — a
/// `0.0` that still exits `0`).
///
/// A payload **missing `minScore`** is an invalid declaration and scores
/// `.bool(false)` with a validation explanation — a judge assertion with no
/// pass bar must never be able to pass. (`CheckpointScorer/score(_:)` is
/// non-throwing, so "reject" surfaces as a red row rather than a thrown
/// error — strictly the safer direction: it can never be silently inert.)
/// A payload that isn't a judge-request object at all (missing
/// `candidate`/`rubric`, non-object) scores `.unavailable` — the judge was
/// never invocable, which is absence, not a measured failure.
///
/// ## Absence
///
/// Two independent absences, both `.unavailable` (never `.number(0)` or a
/// fabricated pass — the module-wide "absence is never scored as a failure"
/// convention `BuiltInCheckpointScorers` already follows), each tagged with a
/// structural `"reason"` metadata key so downstream tooling doesn't have to
/// parse explanation prose:
/// - `"reason": "judge-absent"` — no `EvalJudge` wired into this scorer
///   (`judge: nil`): the checkpoint declared the assertion, but the app
///   hasn't registered a real conformer yet.
/// - `"reason": "judge-error"` — the judge call *threw* (subprocess failure,
///   timeout, malformed response): logged, and surfaced as `.unavailable`
///   with the error in the explanation — a transport failure is not evidence
///   the assertion failed, so it must not silently downgrade to
///   `.bool(false)`.
///
/// (A checkpoint that declares no `custom` payload for this scorer's `id` at
/// all also scores `.unavailable` — distinct from "no scorer registered",
/// which ``GoldenTaskRunner`` already handles at the batch level.)
///
/// ## Request identity
///
/// The ``JudgeRequest/id`` handed to the judge is
/// `"\(context.fixtureID)#\(checkpoint.displayLabel)"`, taken from the
/// ``CheckpointEvaluationContext`` the runner builds — not from a
/// constructor parameter — so it can never drift from the fixture actually
/// being evaluated. It is diagnostic only; it is deliberately NOT part of
/// ``CachingJudge``'s cache key (see ``JudgeCacheKey``).
public struct JudgedCheckpointScorer: CheckpointScorer {
    public let id: String
    private let judge: (any EvalJudge)?

    public init(id: String, judge: (any EvalJudge)?) {
        self.id = id
        self.judge = judge
    }

    public func score(_ context: CheckpointEvaluationContext) async -> Score {
        guard let judge else {
            return Score(
                value: .unavailable,
                explanation: "no EvalJudge registered for custom key '\(id)'",
                metadata: ["assertion": "custom", "scorerID": id, "reason": "judge-absent"]
            )
        }
        guard let payload = context.checkpoint.custom?[id] else {
            return Score(
                value: .unavailable,
                explanation: "checkpoint '\(context.checkpoint.displayLabel)' declares no custom payload for scorer id '\(id)'",
                metadata: ["assertion": "custom", "scorerID": id, "reason": "no-payload"]
            )
        }

        switch Self.decode(payload, fixtureID: context.fixtureID, checkpointLabel: context.checkpoint.displayLabel) {
        case .malformed:
            return Score(
                value: .unavailable,
                explanation: "custom payload for '\(id)' is not a judge-request object (expected fields: candidate (string), rubric (string), minScore (number); optional: content, reference (strings))",
                metadata: ["assertion": "custom", "scorerID": id, "reason": "invalid-payload"]
            )
        case .missingMinScore:
            return Score(
                value: .bool(false),
                explanation: "invalid judged payload for '\(id)': no minScore declared — a judge assertion with no pass bar can never pass; declare \"minScore\" (0.0–1.0) in the payload",
                metadata: ["assertion": "custom", "scorerID": id, "reason": "missing-minScore"]
            )
        case .valid(let request, let minScore):
            do {
                let verdict = try await judge.judge(request)
                let passed = verdict.score >= minScore
                return Score(
                    value: .bool(passed),
                    explanation: "judge score \(Self.format(verdict.score)) vs minScore \(Self.format(minScore)): \(verdict.rationale)",
                    metadata: [
                        "assertion": "custom",
                        "scorerID": id,
                        "judgeScore": Self.format(verdict.score),
                        "minScore": Self.format(minScore),
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
                    metadata: ["assertion": "custom", "scorerID": id, "reason": "judge-error"]
                )
            }
        }
    }

    // MARK: - Payload decoding

    private enum DecodedPayload {
        /// Not a judge-request object at all — absence, not failure.
        case malformed
        /// A judge-request object with no `minScore` — an invalid
        /// declaration that must fail, never pass or read as absence.
        case missingMinScore
        case valid(JudgeRequest, minScore: Double)
    }

    private static func decode(
        _ payload: JSONValue,
        fixtureID: String,
        checkpointLabel: String
    ) -> DecodedPayload {
        guard case .object(let object) = payload else { return .malformed }
        guard case .string(let candidate)? = object["candidate"] else { return .malformed }
        guard case .string(let rubric)? = object["rubric"] else { return .malformed }

        guard case .number(let minScore)? = object["minScore"] else { return .missingMinScore }

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

        let request = JudgeRequest(
            id: "\(fixtureID)#\(checkpointLabel)",
            content: content,
            candidate: candidate,
            reference: reference,
            rubric: rubric
        )
        return .valid(request, minScore: minScore)
    }

    /// Fixed-precision score formatting, matching
    /// ``AppEvalMarkdownRenderer``'s `%.4f` convention for [0,1] values.
    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
