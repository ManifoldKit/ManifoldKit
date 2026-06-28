import Foundation

/// Scores free-form output by cosine similarity of on-device sentence embeddings.
///
/// ## What this measures — and what it does NOT
///
/// Uses whatever ``EmbeddingBackend`` is injected (e.g. Apple's general-purpose
/// `NLEmbedding`), **not** an eval-tuned model. Cosine measures *topical
/// relatedness*, not *correctness*: a wrong-but-on-topic answer (wrong city, a
/// negated claim, a swapped entity) can score as high as the right one. Treat the
/// result as a **screening signal for free-form prose**, not a graded verdict for
/// factual or short-answer tasks — use exact / contains / rubric scorers for those.
///
/// `value` is the raw cosine over L2-normalized vectors. `threshold` is
/// caller-supplied (there is no universal cutoff; promptfoo uses 0.75 as a
/// *starting point*, not a guarantee); `metadata["passed"]` records the
/// thresholded decision. Empty or unembeddable input, or an embedding failure,
/// yields ``ScoreValue/unavailable`` — never `number(0)`, which would misread as
/// "maximally wrong".
public struct SemanticSimilarityScorer: EvalScorer {
    public typealias Expected = String

    private let embedder: any EmbeddingBackend
    private let threshold: Double

    /// - Parameters:
    ///   - embedder: the on-device embedding backend to score with.
    ///   - threshold: the cosine cutoff for the `metadata["passed"]` decision.
    ///     Required by design — no default, because no cutoff is universally valid.
    public init(embedder: any EmbeddingBackend, threshold: Double) {
        self.embedder = embedder
        self.threshold = threshold
    }

    public func score(output: EvalRunOutput, expected: String) async -> Score {
        let candidate = output.visibleText
        do {
            let vectors = try await embedder.embed([candidate, expected])
            // The EmbeddingBackend contract guarantees one vector per input on a
            // non-throwing return, but verify rather than trust before indexing.
            guard vectors.count == 2 else {
                return Self.noSignal("embedder returned \(vectors.count) vectors, expected 2")
            }
            guard
                let a = Self.l2normalized(vectors[0]),
                let b = Self.l2normalized(vectors[1])
            else {
                // A zero-norm vector means empty / unembeddable text (e.g. Apple's
                // NLEmbedding returns zeros for such input). No signal — not zero.
                return Self.noSignal("zero-norm embedding (empty or unembeddable input)")
            }
            let cosine = Double(Self.dot(a, b))
            let passed = cosine >= threshold
            return Score(
                value: .number(cosine),
                explanation: passed
                    ? "cosine \(cosine) ≥ threshold \(threshold)"
                    : "cosine \(cosine) < threshold \(threshold)",
                metadata: [
                    "signal": "ok",
                    "threshold": "\(threshold)",
                    "passed": "\(passed)",
                ]
            )
        } catch {
            // Surface the failure (do not swallow) and return an explicit no-signal
            // score so the caller can drop it rather than read it as a zero.
            Log.inference.warning(
                "SemanticSimilarityScorer: embedding failed: \(String(describing: error), privacy: .public)"
            )
            return Self.noSignal("embedding failed: \(error)")
        }
    }

    private static func noSignal(_ reason: String) -> Score {
        Score(value: .unavailable, explanation: reason, metadata: ["signal": "none"])
    }

    /// Returns the L2-normalized vector, or `nil` when the norm is zero (degenerate
    /// input). We normalize here rather than assume the embedder already did —
    /// `EmbeddingBackend` does not guarantee unit-length output.
    private static func l2normalized(_ v: [Float]) -> [Float]? {
        let norm = (v.reduce(Float(0)) { $0 + $1 * $1 }).squareRoot()
        guard norm > 0 else { return nil }
        return v.map { $0 / norm }
    }

    /// Dot product of two equal-length vectors — cosine similarity once both are
    /// L2-normalized.
    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }
}
