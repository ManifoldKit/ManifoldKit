import XCTest
@testable import ManifoldInference

/// Embedding backend that returns a caller-specified vector per input text, so a
/// test can pin exact cosine outcomes (identical / orthogonal / zero / boundary)
/// without a real model. Returns a zero vector for any text not in the map — which
/// is also how the degenerate (empty/unembeddable) path is exercised.
private final class StubEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {
    var isModelLoaded = true
    var dimensions = 3
    private let vectors: [String: [Float]]
    private let throwOnEmbed: Bool

    init(_ vectors: [String: [Float]], throwOnEmbed: Bool = false) {
        self.vectors = vectors
        self.throwOnEmbed = throwOnEmbed
    }

    func loadModel(from url: URL) async throws {}
    func unloadModel() {}

    func embed(_ texts: [String]) async throws -> [[Float]] {
        if throwOnEmbed { throw EmbeddingError.encodingFailed(underlying: StubError.boom) }
        return texts.map { vectors[$0] ?? [Float](repeating: 0, count: dimensions) }
    }

    enum StubError: Error { case boom }
}

final class SemanticSimilarityScorerTests: XCTestCase {

    private func cosine(of score: Score, file: StaticString = #filePath, line: UInt = #line) -> Double? {
        guard case .number(let value) = score.value else { return nil }
        return value
    }

    func testIdenticalEmbeddingsScoreOne() async {
        let backend = StubEmbeddingBackend([
            "the cat sat": [1, 0, 0],
            "the cat sat on the mat": [1, 0, 0],
        ])
        let scorer = SemanticSimilarityScorer(embedder: backend, threshold: 0.75)
        let out = EvalRunOutput(visibleText: "the cat sat")
        let score = await scorer.score(output: out, expected: "the cat sat on the mat")

        XCTAssertEqual(cosine(of: score), 1.0, accuracy: 1e-6)
        XCTAssertEqual(score.metadata["signal"], "ok")
        XCTAssertEqual(score.metadata["passed"], "true")
    }

    func testOrthogonalEmbeddingsScoreZeroButHaveSignal() async {
        // cosine 0.0 is a real "dissimilar" verdict — distinct from `unavailable`.
        let backend = StubEmbeddingBackend([
            "apples": [1, 0, 0],
            "quantum chromodynamics": [0, 1, 0],
        ])
        let scorer = SemanticSimilarityScorer(embedder: backend, threshold: 0.75)
        let score = await scorer.score(
            output: EvalRunOutput(visibleText: "apples"),
            expected: "quantum chromodynamics"
        )
        XCTAssertEqual(cosine(of: score), 0.0, accuracy: 1e-6)
        XCTAssertEqual(score.metadata["signal"], "ok")
        XCTAssertEqual(score.metadata["passed"], "false")
    }

    func testThresholdBoundaryIsInclusive() async {
        // a=[1,0,0], b normalizes to [0.5, .866, 0] → cosine exactly 0.5.
        let backend = StubEmbeddingBackend([
            "a": [1, 0, 0],
            "b": [1, Float(3).squareRoot(), 0],
        ])
        let scorer = SemanticSimilarityScorer(embedder: backend, threshold: 0.5)
        let score = await scorer.score(
            output: EvalRunOutput(visibleText: "a"),
            expected: "b"
        )
        XCTAssertEqual(cosine(of: score) ?? .nan, 0.5, accuracy: 1e-6)
        XCTAssertEqual(score.metadata["passed"], "true", "threshold compare is >=, so exactly-at-threshold passes")
    }

    func testEmptyOutputYieldsUnavailableNotZero() async {
        // Candidate text maps to the default zero vector → no signal, NOT number(0).
        let backend = StubEmbeddingBackend(["reference": [1, 0, 0]])
        let scorer = SemanticSimilarityScorer(embedder: backend, threshold: 0.75)
        let score = await scorer.score(
            output: EvalRunOutput(visibleText: ""),
            expected: "reference"
        )
        XCTAssertEqual(score.value, .unavailable)
        XCTAssertNil(score.value.doubleValue, "no-signal must never read as a numeric zero")
        XCTAssertEqual(score.metadata["signal"], "none")
    }

    func testEmbeddingFailureYieldsUnavailable() async {
        let backend = StubEmbeddingBackend(["x": [1, 0, 0]], throwOnEmbed: true)
        let scorer = SemanticSimilarityScorer(embedder: backend, threshold: 0.75)
        let score = await scorer.score(
            output: EvalRunOutput(visibleText: "x"),
            expected: "x"
        )
        XCTAssertEqual(score.value, .unavailable)
        XCTAssertEqual(score.metadata["signal"], "none")
    }
}
