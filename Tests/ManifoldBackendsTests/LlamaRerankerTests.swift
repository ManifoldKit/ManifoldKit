#if Llama
import XCTest
@testable import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldLlama

/// Tests for the #1637 local cross-encoder reranker (``LlamaReranker``).
///
/// The model-free tests (squash math, not-ready contract) run anywhere. The
/// RANK-pooling end-to-end test needs a reranker GGUF and Metal, so it skips
/// unless `LLAMA_RERANKER_MODEL` points at a cross-encoder model
/// (e.g. `bge-reranker-v2-m3`).
final class LlamaRerankerTests: XCTestCase {

    // MARK: - Model-free contract

    /// The logistic squash must be monotonic and map into (0, 1) so reranked
    /// citation scores are comparable relevance probabilities. A larger logit
    /// must always yield a strictly larger probability.
    func test_sigmoid_isMonotonicAndBounded() {
        // Inputs are kept inside the range where Float32 still represents the
        // result distinctly from the asymptote — at |x| ≳ 16 the squash
        // legitimately saturates to exactly 0 or 1 in single precision, which is
        // correct behaviour, not a bound violation.
        let inputs: [Float] = [-15, -5, -1, 0, 1, 5, 15]
        let outputs = inputs.map { LlamaReranker.sigmoid($0) }

        for value in outputs {
            XCTAssertGreaterThan(value, 0)
            XCTAssertLessThan(value, 1)
        }
        for i in 1..<outputs.count {
            XCTAssertGreaterThan(outputs[i], outputs[i - 1],
                                 "sigmoid must be strictly increasing")
        }
        XCTAssertEqual(LlamaReranker.sigmoid(0), 0.5, accuracy: 1e-6)
    }

    /// Before any model is loaded, `isReady` must be `false` so `RAGService`
    /// never widens or invokes the reranker against a freed context.
    func test_isReady_falseBeforeLoad() {
        let reranker = LlamaReranker()
        XCTAssertFalse(reranker.isReady)
    }

    /// When not ready, `rerank` must honour the ``Reranker`` contract by
    /// returning the first `limit` candidates unchanged — never touching the C
    /// context. This is the safety net behind the `RAGService` gate.
    func test_rerank_whenNotReady_returnsFirstLimitUnchanged() async throws {
        let reranker = LlamaReranker()  // never loaded → not ready
        let docID = UUID()
        let candidates = (0..<5).map {
            VectorSearchHit(
                chunk: DocumentChunk(documentID: docID, text: "p\($0)", chunkIndex: $0),
                documentTitle: "Doc",
                score: Float($0)
            )
        }

        let result = try await reranker.rerank(query: "q", candidates: candidates, limit: 3)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.chunk.chunkIndex), [0, 1, 2],
                       "not-ready reranker must passthrough the first `limit` candidates")
    }

    // MARK: - RANK-pooling end-to-end (model-gated)

    /// Loads a real cross-encoder GGUF and verifies it surfaces the obviously
    /// relevant passage above an unrelated one. Skips unless a reranker model is
    /// configured via `LLAMA_RERANKER_MODEL`.
    func test_rerank_withRealModel_ranksRelevantPassageFirst() async throws {
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaReranker requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaReranker requires Apple Silicon")

        let env = ProcessInfo.processInfo.environment
        guard let rawPath = env["LLAMA_RERANKER_MODEL"], !rawPath.isEmpty else {
            throw XCTSkip("Set LLAMA_RERANKER_MODEL=<path to a cross-encoder reranker GGUF> to run the RANK-pooling end-to-end test.")
        }
        let modelURL = URL(filePath: (rawPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("LLAMA_RERANKER_MODEL does not point at an existing file: \(modelURL.path)")
        }

        let reranker = LlamaReranker()
        addTeardownBlock { reranker.unloadModel() }
        try await reranker.loadModel(from: modelURL)
        XCTAssertTrue(reranker.isReady)

        let docID = UUID()
        let candidates = [
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "The Eiffel Tower is located in Paris, France.", chunkIndex: 0), documentTitle: "Doc", score: 0.5),
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "Photosynthesis converts sunlight into chemical energy in plants.", chunkIndex: 1), documentTitle: "Doc", score: 0.5),
        ]

        let ranked = try await reranker.rerank(query: "Where is the Eiffel Tower?", candidates: candidates, limit: 2)

        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.first?.chunk.chunkIndex, 0,
                       "the cross-encoder must rank the Eiffel-Tower passage above the unrelated one")
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score,
                             "reranked scores must be ordered descending")
    }
}
#endif
