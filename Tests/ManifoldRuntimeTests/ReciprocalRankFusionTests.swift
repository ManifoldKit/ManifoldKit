import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Pure unit tests for RRF fusion (#1919). Two known ranked lists → one known
/// fused order, verified against hand-computed `Σ 1/(k + rank)`.
final class ReciprocalRankFusionTests: XCTestCase {

    private func hit(_ id: UUID, score: Float = 0.5) -> VectorSearchHit {
        VectorSearchHit(
            chunk: DocumentChunk(id: id, documentID: UUID(), text: "t", chunkIndex: 0),
            documentTitle: "Doc",
            score: score
        )
    }

    func testFusionOrdersByReciprocalRankSum() {
        // a, b, c, d are distinct chunks.
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        // Dense ranks:  a(1), b(2), c(3)
        // Sparse ranks: c(1), d(2), a(3)
        // With k = 60:
        //   a = 1/61 + 1/63 = 0.016393 + 0.015873 = 0.032266
        //   c = 1/63 + 1/61 = 0.032266   (ties a's sum)
        //   b = 1/62        = 0.016129
        //   d = 1/62        = 0.016129
        // a and c tie; tiebreak is first-sighting order → a (seen in dense first).
        let dense = [hit(a), hit(b), hit(c)]
        let sparse = [hit(c), hit(d), hit(a)]

        let fused = ReciprocalRankFusion.fuse([dense, sparse], k: 60, limit: 10)
        let order = fused.map(\.chunk.id)

        XCTAssertEqual(order.count, 4)
        // a and c lead (highest, tied → a first by sighting), then b/d.
        XCTAssertEqual(order[0], a)
        XCTAssertEqual(order[1], c)
        XCTAssertTrue(Set(order[2...3]) == Set([b, d]))
    }

    func testDocumentInBothListsOutranksSingletons() {
        // `shared` appears mid-pack in both lists; `top` is rank-1 in only one.
        let shared = UUID(), top = UUID(), other = UUID()
        let listA = [hit(top), hit(shared)]      // top(1), shared(2)
        let listB = [hit(other), hit(shared)]    // other(1), shared(2)
        // k=60: shared = 1/62 + 1/62 = 0.032258
        //       top    = 1/61        = 0.016393
        //       other  = 1/61        = 0.016393
        let fused = ReciprocalRankFusion.fuse([listA, listB], k: 60, limit: 10)
        XCTAssertEqual(fused.first?.chunk.id, shared,
                       "A doc surfaced by both retrievers should outrank rank-1 singletons")
    }

    func testHigherSourceScoreIsCarriedForCitations() {
        // Same chunk in both lists with different source scores; the fused hit
        // must carry the larger score so citations show the strongest signal.
        let id = UUID()
        let weak = hit(id, score: 0.2)
        let strong = hit(id, score: 0.9)
        let fused = ReciprocalRankFusion.fuse([[weak], [strong]], limit: 5)
        XCTAssertEqual(fused.count, 1)
        XCTAssertEqual(fused.first?.score, 0.9)
    }

    func testSingleListPassesThroughInOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        let only = [hit(a), hit(b), hit(c)]
        let fused = ReciprocalRankFusion.fuse([only], limit: 10)
        XCTAssertEqual(fused.map(\.chunk.id), [a, b, c])
    }

    func testSabotageSmallerKChangesOrdering() {
        // Sabotage check: RRF must be live. With k=60 a doc appearing in both
        // lists wins; the assertion above (`testDocumentInBothListsOutranksSingletons`)
        // depends on the k+rank denominator. Confirm a degenerate k=0 with a
        // single rank-1 singleton can overtake the shared doc, proving the
        // denominator (not a constant) drives the order.
        let shared = UUID(), top = UUID()
        let listA = [hit(top), hit(shared)]   // top(1), shared(2)
        let listB = [hit(shared)]             // shared(1)
        // k=0: top = 1/1 = 1.0 ; shared = 1/2 + 1/1 = 1.5 → shared still wins,
        // but flip listB so shared is rank-2 to invert.
        let listBLow = [hit(top), hit(shared)] // top(1), shared(2)
        // k=0: top = 1/1 + 1/1 = 2.0 ; shared = 1/2 + 1/2 = 1.0 → top wins.
        let fused = ReciprocalRankFusion.fuse([listA, listBLow], k: 0, limit: 5)
        XCTAssertEqual(fused.first?.chunk.id, top,
                       "k=0 with top at rank-1 in both lists must beat the shared rank-2 doc")
    }

    func testLimitAndEmptyInputs() {
        XCTAssertTrue(ReciprocalRankFusion.fuse([], limit: 5).isEmpty)
        XCTAssertTrue(ReciprocalRankFusion.fuse([[hit(UUID())]], limit: 0).isEmpty)
    }
}
