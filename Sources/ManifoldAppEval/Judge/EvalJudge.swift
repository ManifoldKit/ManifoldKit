import Foundation

// MARK: - JudgeRequest

/// A generic fuzzy-assertion grading request handed to a registered
/// ``EvalJudge``.
///
/// This is the seam wave 2a generalizes out of fireside's `ClaudeCodeJudge`
/// (design v2 §3.5): the harness spine is the protocol + cache, never the
/// concrete invocation (subprocess, HTTP call, …), which stays app-specific.
/// `JudgeRequest` is deliberately generic enough to carry fireside's
/// `ExtractionDelta`-vs-`ExtractionDelta` comparison as one instance —
/// `candidate` and `reference` are pre-serialized strings (an app JSON-encodes
/// its own domain type before constructing the request; this module has no
/// dependency on any app's domain types), `content` is the freeform grounding
/// text a rubric refers to (a scene, a transcript slice), and `rubric` is the
/// grading instruction specific to the checkpoint declaring the assertion.
///
/// ## Policy: last resort, not first choice
///
/// Every built-in ``GoldenCheckpoint`` assertion (`requiredContent`,
/// `expectedEvents`, `expectedToolCalls`, `expectedCompression`,
/// `expectedContextSlots`) is exact and deterministic. Reach for a judge only
/// when an assertion genuinely can't be expressed mechanically — see the
/// module's DocC page, "Machine-checkable first, judge only for genuinely
/// fuzzy assertions."
public struct JudgeRequest: Sendable, Equatable {
    /// Diagnostic label for this request — typically
    /// `"\(fixtureID)#\(checkpointLabel)"` — for logging and judge-side
    /// telemetry. Deliberately **not** part of ``CachingJudge``'s cache key
    /// (``JudgeCacheKey`` hashes content fields only): renaming a fixture or
    /// checkpoint must not re-bill identical judgments, and two checkpoints
    /// grading identical content should share one cache entry.
    public let id: String

    /// The grounding text the rubric refers to — a scene, a transcript slice,
    /// or empty when the candidate/reference comparison is self-contained.
    public let content: String

    /// The system-under-test's output, serialized to a comparable string
    /// (e.g. pretty-printed sorted-key JSON of a domain delta type).
    public let candidate: String

    /// The ground-truth baseline `candidate` is graded against, serialized
    /// the same way. `nil` for rubric-only grading with no reference (e.g.
    /// "is this response harmful").
    ///
    /// What `nil` *means* to the grader is conformer-defined: a conformer
    /// whose prompt template requires a reference should `throw` on a
    /// `nil`-reference request (surfacing as a judge error → `.unavailable`
    /// via ``JudgedCheckpointScorer``), never silently substitute an empty
    /// baseline.
    public let reference: String?

    /// Grading instructions: what a high vs. low score means for this
    /// specific assertion. Distinct per checkpoint, not a module-wide
    /// constant — the checkpoint author owns the rubric.
    public let rubric: String

    public init(
        id: String,
        content: String = "",
        candidate: String,
        reference: String? = nil,
        rubric: String
    ) {
        self.id = id
        self.content = content
        self.candidate = candidate
        self.reference = reference
        self.rubric = rubric
    }
}

// MARK: - JudgeVerdict

/// A judge's verdict on one ``JudgeRequest``.
///
/// `Codable` (unlike ``EvalScore``, which is deliberately not — see
/// `Score.swift`'s doc comment): `JudgeVerdict` is the on-disk shape
/// ``CachingJudge`` persists, so its Codable conformance is load-bearing from
/// day one, not a speculative addition.
public struct JudgeVerdict: Sendable, Equatable, Codable {
    /// Quality score, conventionally 0.0–1.0 (1.0 = fully correct, 0.0 =
    /// hallucinated/completely wrong). Not clamped by this type — a judge
    /// conformer producing an out-of-range value is the conformer's defect to
    /// fix, not this seam's to silently mask (this repo validates at system
    /// boundaries, not internal invariants the type system can't express
    /// anyway: `Double` has no [0,1] subtype).
    public let score: Double

    /// Human-readable justification for `score`.
    public let rationale: String

    /// Categorical failure-mode tags (e.g. `"hallucinated_entity"`,
    /// `"missed_relationship"`). Empty when the judge has nothing to flag.
    public let flags: [String]

    public init(score: Double, rationale: String, flags: [String] = []) {
        self.score = score
        self.rationale = rationale
        self.flags = flags
    }
}

// MARK: - EvalJudge

/// Grades a ``JudgeRequest`` and returns a ``JudgeVerdict``.
///
/// This protocol is the entire harness-side judge surface — no subprocess
/// invocation, no HTTP client, no model-specific prompt template lives in
/// ManifoldKit. First production conformer: fireside's `ClaudeCodeJudge`
/// (subprocess `claude -p --output-format=json`, prompt template,
/// JSON-envelope parsing) — fireside PR #901, drafted against this branch;
/// both PRs ready only after the next MK release, so protocol and conformer
/// land in the same release train. See the module DocC page for the
/// liveness plan.
///
/// `judge(_:)` is `async throws`, not a plain `async` return: a real judge
/// conformer's failure modes (subprocess timeout, non-zero exit, malformed
/// response) are genuine errors, not a `0.0` score — collapsing them into a
/// fabricated verdict would violate the "absence is never scored as a
/// failure" convention the built-in scorers already follow throughout this
/// module. Callers that route a judge through ``JudgedCheckpointScorer``
/// get that translation (`ScoreValue.unavailable`, never `.number(0)`) for free.
public protocol EvalJudge: Sendable {
    func judge(_ request: JudgeRequest) async throws -> JudgeVerdict
}
