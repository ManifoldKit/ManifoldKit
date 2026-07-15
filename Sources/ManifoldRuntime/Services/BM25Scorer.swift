import Foundation

// MARK: - BM25Scorer

/// Pure, in-memory BM25 sparse scorer over a fixed document corpus.
///
/// BM25 is the standard probabilistic term-weighting ranking function. Unlike
/// the legacy substring `keywordSearch` (which scored every match a flat `1.0`),
/// BM25 rewards documents where a query term is *frequent locally* but *rare in
/// the corpus*, and dampens long documents that match by length alone. This is
/// what lets the sparse leg of hybrid retrieval surface exact rare tokens
/// (codes, identifiers, jargon) that a dense embedding glosses over.
///
/// The scorer is intentionally a value type with no I/O: callers build it from
/// the corpus already in memory (`FlatFileVectorStore` loads every record), then
/// query it. Keeping it pure makes the ranking unit-testable against a hand-
/// computed expected order without touching persistence.
///
/// Scoring (Robertson/Spärck-Jones BM25):
///
/// ```
/// score(D, Q) = Σ_{t ∈ Q}  idf(t) · ( tf(t,D) · (k1 + 1) )
///                                    ─────────────────────────────────────
///                                    tf(t,D) + k1 · (1 − b + b · |D| / avgdl)
/// ```
///
/// with the standard IDF variant
/// `idf(t) = ln( (N − df(t) + 0.5) / (df(t) + 0.5) + 1 )`. The `+ 1` inside the
/// log keeps IDF non-negative even for terms appearing in more than half the
/// corpus, so a common term can never *subtract* from a document's score.
package struct BM25Scorer: Sendable {

    /// One indexed document: its identity plus the pre-tokenized term counts and
    /// length needed to score it. `id` is opaque to the scorer — callers map it
    /// back to whatever record type they hold.
    package struct Document: Sendable {
        package let id: UUID
        /// Term → frequency within this document.
        let termFrequencies: [String: Int]
        /// Total token count (sum of term frequencies); the BM25 `|D|`.
        let length: Int
    }

    /// Standard BM25 term-frequency saturation parameter. 1.2 is the canonical
    /// default (Robertson et al.); higher values let raw term frequency matter
    /// more before saturating. PROVISIONAL until the eval harness (#1937) lands.
    package static let defaultK1: Double = 1.2

    /// Standard BM25 length-normalization parameter in `[0, 1]`. 0.75 is the
    /// canonical default; `b = 0` disables length normalization entirely, `b = 1`
    /// applies it fully. PROVISIONAL until #1937.
    package static let defaultB: Double = 0.75

    private let documents: [Document]
    /// term → number of documents containing it (document frequency).
    private let documentFrequency: [String: Int]
    private let averageDocumentLength: Double
    private let documentCount: Int
    private let k1: Double
    private let b: Double

    /// Builds an index from raw `(id, text)` pairs.
    ///
    /// Tokenization and the document-frequency table are computed once here so
    /// each subsequent `score(query:limit:)` is O(|Q| · N) rather than re-walking
    /// the corpus for IDF on every query.
    package init(
        corpus: [(id: UUID, text: String)],
        k1: Double = BM25Scorer.defaultK1,
        b: Double = BM25Scorer.defaultB
    ) {
        self.k1 = k1
        self.b = b

        var docs: [Document] = []
        docs.reserveCapacity(corpus.count)
        var df: [String: Int] = [:]
        var totalLength = 0

        for entry in corpus {
            let tokens = BM25Scorer.tokenize(entry.text)
            var tf: [String: Int] = [:]
            for token in tokens { tf[token, default: 0] += 1 }
            // Document frequency counts *documents* containing the term, not
            // occurrences — so iterate the distinct keys, not the token list.
            for term in tf.keys { df[term, default: 0] += 1 }
            totalLength += tokens.count
            docs.append(Document(id: entry.id, termFrequencies: tf, length: tokens.count))
        }

        self.documents = docs
        self.documentFrequency = df
        self.documentCount = docs.count
        // Guard the empty corpus so `|D| / avgdl` never divides by zero.
        self.averageDocumentLength = docs.isEmpty
            ? 0
            : Double(totalLength) / Double(docs.count)
    }

    /// Scores every document against `query` and returns the top `limit` by
    /// descending BM25 score. Documents scoring `0` (no query term matched) are
    /// dropped — they carry no sparse signal and would only dilute the fused
    /// ranking.
    package func score(query: String, limit: Int) -> [(id: UUID, score: Double)] {
        guard limit > 0, documentCount > 0 else { return [] }
        let queryTerms = Set(BM25Scorer.tokenize(query))
        guard !queryTerms.isEmpty else { return [] }

        // Precompute IDF per query term once; it is document-independent.
        var idf: [String: Double] = [:]
        for term in queryTerms {
            let df = documentFrequency[term] ?? 0
            idf[term] = BM25Scorer.idf(documentFrequency: df, documentCount: documentCount)
        }

        var scored: [(id: UUID, score: Double)] = []
        for doc in documents {
            var score = 0.0
            for term in queryTerms {
                guard let tf = doc.termFrequencies[term], tf > 0 else { continue }
                guard let termIDF = idf[term], termIDF > 0 else { continue }
                let numerator = Double(tf) * (k1 + 1)
                let denominator = Double(tf)
                    + k1 * (1 - b + b * Double(doc.length) / max(averageDocumentLength, 1))
                score += termIDF * (numerator / denominator)
            }
            if score > 0 { scored.append((doc.id, score)) }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Tokenization

    /// Lowercases and splits on any non-alphanumeric boundary.
    ///
    /// Deliberately simple: matches the term model the sparse leg needs (exact
    /// token overlap for codes/identifiers) without a stemmer or stop-word list,
    /// which would add language-specific behaviour the eval harness hasn't
    /// validated yet. Unicode-aware via `CharacterSet.alphanumerics`.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Robertson/Spärck-Jones IDF with the `+ 1` smoothing that keeps the value
    /// non-negative for terms appearing in over half the corpus.
    static func idf(documentFrequency df: Int, documentCount n: Int) -> Double {
        guard n > 0 else { return 0 }
        return log((Double(n) - Double(df) + 0.5) / (Double(df) + 0.5) + 1)
    }
}
