import Foundation

/// Hand-authored fixture corpus and golden-query labels for the RAG
/// retrieval-eval harness (#1937).
///
/// The corpus is **hand-labelled ground truth** — the honest baseline against
/// which retrieval-quality changes (#1919 RRF, #1920 cloud rerank) are measured.
/// Synthetic Q&A generation is deferred (it needs a live model); hand labels are
/// more trustworthy as a regression baseline anyway.
///
/// ## Design constraints
///
/// - **One chunk per document.** Each `text` is well under the default
///   ``DocumentChunker`` `chunkSize` (1800 chars), so every document ingests as
///   a single chunk at index 0. That makes "document relevant" and "chunk
///   relevant" coincide, which is what lets ``GoldenQuery`` key relevance by
///   document title (the only stable identifier a ``Citation`` exposes).
/// - **Distinct topics with lexical overlap.** Documents span unrelated subjects
///   so the hashing (bag-of-words) embedding can separate them, and each golden
///   query shares surface vocabulary with its relevant document(s).
/// - **Rare/exact-token documents.** A few documents carry unique identifiers
///   (`error code `RAG-7731``, the `ZX-409` part number, the `BL-22A`
///   coordinate) precisely to exercise the sparse / exact-match retrieval path
///   #1919 will improve. Their golden queries quote the identifier verbatim.
///
/// Titles are the file stems (`RAGService` derives the title from the source
/// file name sans extension), so `relevantDocumentTitles` must match the stems
/// in ``EvalDocument/title``.
public enum RAGEvalCorpus {

    /// A single fixture document: a stable title and its full text.
    public struct EvalDocument: Sendable, Hashable {
        public let title: String
        public let text: String

        public init(title: String, text: String) {
            self.title = title
            self.text = text
        }
    }

    /// The fixture corpus: 16 short, single-chunk documents across distinct
    /// topics, several carrying rare exact-match identifiers.
    public static let documents: [EvalDocument] = [
        EvalDocument(
            title: "photosynthesis",
            text: "Photosynthesis is the process by which green plants convert sunlight, water, and carbon dioxide into glucose and oxygen. It takes place in the chloroplasts of plant cells."
        ),
        EvalDocument(
            title: "mitochondria",
            text: "Mitochondria are the powerhouse of the cell. They generate most of the cell's supply of ATP through cellular respiration, using oxygen and glucose to release energy."
        ),
        EvalDocument(
            title: "tcp-handshake",
            text: "The TCP three-way handshake establishes a reliable connection. The client sends a SYN packet, the server replies with SYN-ACK, and the client confirms with an ACK before data transfer begins."
        ),
        EvalDocument(
            title: "dns-resolution",
            text: "DNS resolution translates a human-readable domain name into an IP address. A recursive resolver queries root, top-level-domain, and authoritative name servers until it returns the address record."
        ),
        EvalDocument(
            title: "black-holes",
            text: "A black hole is a region of spacetime where gravity is so strong that nothing, not even light, can escape. The boundary beyond which escape is impossible is called the event horizon."
        ),
        EvalDocument(
            title: "supernova",
            text: "A supernova is a powerful stellar explosion that occurs when a massive star exhausts its nuclear fuel and collapses, briefly outshining an entire galaxy and dispersing heavy elements into space."
        ),
        EvalDocument(
            title: "espresso",
            text: "Espresso is brewed by forcing nearly boiling water under high pressure through finely ground coffee. The result is a concentrated shot topped with a layer of crema."
        ),
        EvalDocument(
            title: "sourdough",
            text: "Sourdough bread is leavened by a natural starter of wild yeast and lactobacilli rather than commercial yeast. The long fermentation gives it a tangy flavour and chewy crust."
        ),
        EvalDocument(
            title: "compound-interest",
            text: "Compound interest is interest calculated on both the initial principal and the accumulated interest from previous periods. Over time it causes savings or debt to grow exponentially."
        ),
        EvalDocument(
            title: "inflation",
            text: "Inflation is the rate at which the general level of prices for goods and services rises, eroding purchasing power. Central banks often raise interest rates to bring high inflation back under control."
        ),
        EvalDocument(
            title: "photosynthesis-light",
            text: "The light-dependent reactions of photosynthesis occur in the thylakoid membranes, where chlorophyll absorbs photons to split water and produce ATP and NADPH for the Calvin cycle."
        ),
        EvalDocument(
            title: "garbage-collection",
            text: "Automatic garbage collection reclaims memory occupied by objects that are no longer reachable. Tracing collectors mark live objects from a set of roots and then sweep the unmarked remainder."
        ),
        // --- Rare / exact-token documents for the sparse-retrieval path (#1919) ---
        EvalDocument(
            title: "error-code-rag7731",
            text: "Troubleshooting note: error code RAG-7731 indicates that the vector index failed to load because the on-disk dimension count did not match the embedding backend. Re-ingest the corpus to regenerate the index."
        ),
        EvalDocument(
            title: "part-zx409",
            text: "The ZX-409 hydraulic coupling is rated for 350 bar and fits the Mark IV manifold. Replace the O-ring seal whenever the ZX-409 is removed for inspection."
        ),
        EvalDocument(
            title: "grid-bl22a",
            text: "Survey marker BL-22A is located at the north-east corner of sector twelve. All elevation readings in this district are referenced against the BL-22A benchmark."
        ),
        EvalDocument(
            title: "config-flag-xenon",
            text: "Setting the experimental XENON_FASTPATH flag enables the low-latency scheduler. The XENON_FASTPATH path is disabled by default because it bypasses several safety checks."
        ),
    ]

    /// Hand-labelled golden queries (30) mapping a natural-language query to the
    /// document title(s) whose retrieval is correct ground truth.
    ///
    /// Most are single-relevant; a handful are multi-relevant (both
    /// photosynthesis documents; both astronomy documents) to exercise recall
    /// over a relevant set larger than one.
    public static let goldenQueries: [GoldenQuery] = [
        // --- Single-topic semantic queries ---
        GoldenQuery(query: "How do plants make food from sunlight?", relevantDocumentTitles: ["photosynthesis", "photosynthesis-light"]),
        GoldenQuery(query: "What converts glucose and oxygen into ATP in the cell?", relevantDocumentTitles: ["mitochondria"]),
        GoldenQuery(query: "Explain the powerhouse of the cell", relevantDocumentTitles: ["mitochondria"]),
        GoldenQuery(query: "How does a client establish a reliable TCP connection?", relevantDocumentTitles: ["tcp-handshake"]),
        GoldenQuery(query: "What is the SYN SYN-ACK ACK sequence?", relevantDocumentTitles: ["tcp-handshake"]),
        GoldenQuery(query: "How is a domain name translated into an IP address?", relevantDocumentTitles: ["dns-resolution"]),
        GoldenQuery(query: "What does a recursive resolver query?", relevantDocumentTitles: ["dns-resolution"]),
        GoldenQuery(query: "What is the event horizon of a black hole?", relevantDocumentTitles: ["black-holes"]),
        GoldenQuery(query: "Why can light not escape from a black hole?", relevantDocumentTitles: ["black-holes"]),
        GoldenQuery(query: "What happens when a massive star exhausts its nuclear fuel?", relevantDocumentTitles: ["supernova"]),
        GoldenQuery(query: "Which stellar explosion disperses heavy elements into space?", relevantDocumentTitles: ["supernova"]),
        GoldenQuery(query: "How is espresso coffee brewed under pressure?", relevantDocumentTitles: ["espresso"]),
        GoldenQuery(query: "What gives espresso its crema?", relevantDocumentTitles: ["espresso"]),
        GoldenQuery(query: "How is sourdough bread leavened with wild yeast?", relevantDocumentTitles: ["sourdough"]),
        GoldenQuery(query: "What makes sourdough taste tangy?", relevantDocumentTitles: ["sourdough"]),
        GoldenQuery(query: "How does interest on accumulated interest grow savings?", relevantDocumentTitles: ["compound-interest"]),
        GoldenQuery(query: "Why does compound interest grow exponentially over time?", relevantDocumentTitles: ["compound-interest"]),
        GoldenQuery(query: "What erodes purchasing power as prices rise?", relevantDocumentTitles: ["inflation"]),
        GoldenQuery(query: "Why do central banks raise interest rates to fight rising prices?", relevantDocumentTitles: ["inflation"]),
        GoldenQuery(query: "Where do the light-dependent reactions and chlorophyll absorb photons?", relevantDocumentTitles: ["photosynthesis-light", "photosynthesis"]),
        GoldenQuery(query: "How does tracing garbage collection reclaim unreachable memory?", relevantDocumentTitles: ["garbage-collection"]),
        GoldenQuery(query: "What marks live objects from roots and sweeps the remainder?", relevantDocumentTitles: ["garbage-collection"]),
        // --- Rare / exact-token queries (sparse path, #1919) ---
        GoldenQuery(query: "What does error code RAG-7731 mean?", relevantDocumentTitles: ["error-code-rag7731"]),
        GoldenQuery(query: "Why did the vector index fail with RAG-7731?", relevantDocumentTitles: ["error-code-rag7731"]),
        GoldenQuery(query: "What pressure is the ZX-409 hydraulic coupling rated for?", relevantDocumentTitles: ["part-zx409"]),
        GoldenQuery(query: "When should the ZX-409 O-ring seal be replaced?", relevantDocumentTitles: ["part-zx409"]),
        GoldenQuery(query: "Where is survey marker BL-22A located?", relevantDocumentTitles: ["grid-bl22a"]),
        GoldenQuery(query: "What benchmark are elevation readings referenced against, BL-22A?", relevantDocumentTitles: ["grid-bl22a"]),
        GoldenQuery(query: "What does the XENON_FASTPATH flag enable?", relevantDocumentTitles: ["config-flag-xenon"]),
        GoldenQuery(query: "Why is XENON_FASTPATH disabled by default?", relevantDocumentTitles: ["config-flag-xenon"]),
    ]

    /// Writes every fixture document to a uniquely-named temp directory as a
    /// `.txt` file and returns the URLs, in corpus order. The file stem is the
    /// document title, so the title `RAGService` derives at ingest matches the
    /// golden labels.
    ///
    /// The caller owns the returned directory and should remove it on teardown
    /// (the parent directory is the first URL's `deletingLastPathComponent()`).
    ///
    /// - Throws: Any file-write error.
    public static func writeDocuments() throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rag-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try documents.map { doc in
            let url = dir.appendingPathComponent("\(doc.title).txt")
            try doc.text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }
}
