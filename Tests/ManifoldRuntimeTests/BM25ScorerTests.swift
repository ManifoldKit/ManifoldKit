import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Pure unit tests for the BM25 sparse scorer (#1919). No persistence — the
/// scorer is a value type built directly from an in-memory corpus.
final class BM25ScorerTests: XCTestCase {

    // MARK: - Tokenization

    func testTokenizeLowercasesAndSplitsOnNonAlphanumerics() {
        let tokens = BM25Scorer.tokenize("Error-Code: ABC_123!!")
        XCTAssertEqual(tokens, ["error", "code", "abc", "123"])
    }

    // MARK: - IDF

    func testIDFRewardsRareTerms() {
        // A term in 1 of 100 docs must outweigh a term in 90 of 100 docs.
        let rare = BM25Scorer.idf(documentFrequency: 1, documentCount: 100)
        let common = BM25Scorer.idf(documentFrequency: 90, documentCount: 100)
        XCTAssertGreaterThan(rare, common)
        // The `+1` smoothing keeps IDF non-negative even past 50% frequency.
        XCTAssertGreaterThanOrEqual(common, 0)
    }

    // MARK: - Ranking

    func testRareTermDocumentOutranksCommonTermDocument() {
        // Corpus: "engine" appears everywhere (common, low IDF); "xz9plasma"
        // appears in exactly one doc (rare, high IDF). A query for both terms
        // must rank the doc containing the rare token first — impossible under
        // the legacy constant-1.0 keyword scorer.
        let rareID = UUID()
        let commonID = UUID()
        let corpus: [(id: UUID, text: String)] = [
            (rareID, "the engine xz9plasma module"),
            (commonID, "the engine runs the engine again"),
            (UUID(), "engine engine engine"),
            (UUID(), "an engine here"),
        ]
        let scorer = BM25Scorer(corpus: corpus)
        let ranked = scorer.score(query: "engine xz9plasma", limit: 10)

        XCTAssertFalse(ranked.isEmpty)
        XCTAssertEqual(ranked.first?.id, rareID,
                       "Document with the rare query term must rank first")
        // The common-only doc must score strictly below the rare-term doc.
        let rareScore = ranked.first { $0.id == rareID }?.score ?? 0
        let commonScore = ranked.first { $0.id == commonID }?.score ?? 0
        XCTAssertGreaterThan(rareScore, commonScore)
    }

    func testTermFrequencyIncreasesScoreWithSaturation() {
        // Two docs of equal length; one mentions the query term twice, the other
        // once. Higher tf must score higher (BM25 numerator grows with tf).
        let twiceID = UUID()
        let onceID = UUID()
        let corpus: [(id: UUID, text: String)] = [
            (twiceID, "alpha alpha beta gamma"),
            (onceID, "alpha beta gamma delta"),
        ]
        let scorer = BM25Scorer(corpus: corpus)
        let ranked = scorer.score(query: "alpha", limit: 10)
        XCTAssertEqual(ranked.first?.id, twiceID)
    }

    func testZeroMatchDocumentsAreDropped() {
        let matchID = UUID()
        let corpus: [(id: UUID, text: String)] = [
            (matchID, "needle in haystack"),
            (UUID(), "completely unrelated text"),
        ]
        let scorer = BM25Scorer(corpus: corpus)
        let ranked = scorer.score(query: "needle", limit: 10)
        // Only the matching document survives; the other contributes no signal.
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.id, matchID)
    }

    func testEmptyCorpusAndEmptyQueryReturnNothing() {
        let empty = BM25Scorer(corpus: [])
        XCTAssertTrue(empty.score(query: "anything", limit: 5).isEmpty)

        let scorer = BM25Scorer(corpus: [(UUID(), "some text here")])
        XCTAssertTrue(scorer.score(query: "", limit: 5).isEmpty)
        XCTAssertTrue(scorer.score(query: "text", limit: 0).isEmpty)
    }

    func testAllEngineDocsScoreWhenDFEqualsN() {
        // Reproduces the store-test corpus: "engine" in all 3 docs (df == N).
        let corpus: [(id: UUID, text: String)] = [
            (UUID(), "engine xz9plasma module"),
            (UUID(), "engine engine engine"),
            (UUID(), "an engine somewhere"),
        ]
        let scorer = BM25Scorer(corpus: corpus)
        let ranked = scorer.score(query: "engine xz9plasma", limit: 5)
        XCTAssertEqual(ranked.count, 3, "df==N still yields positive IDF; all matches must score")
    }

    func testLimitTruncatesToTopK() {
        let corpus = (0..<5).map { i in (UUID(), "match token number \(i)") }
        let scorer = BM25Scorer(corpus: corpus)
        let ranked = scorer.score(query: "match", limit: 2)
        XCTAssertEqual(ranked.count, 2)
    }
}
