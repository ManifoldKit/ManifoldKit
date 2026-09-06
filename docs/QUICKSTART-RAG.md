# ManifoldKit RAG Quickstart

**Audience:** consumer
**Status:** living

A one-page tutorial for adding on-device **retrieval-augmented generation** —
ingest your own documents, have ManifoldKit retrieve the most relevant passages
before each turn, and surface inline source **citations** beneath every
assistant reply. Retrieval is wired into the turn loop, so once RAG is
configured your existing `ChatView` "just answers from the documents" with no
per-turn code.

> **What ships today.** Document parsing (`.txt`, `.md`, `.pdf`), chunking, a
> flat-file vector index, semantic search via an optional on-device embedding
> model, a keyword-search fallback when no embedding model is loaded, an
> optional cross-encoder **rerank** stage, and per-passage citations rendered in
> `ChatView`. All on-device — nothing is sent to a server for indexing.

---

## How it fits together

RAG is opt-in through [`RAGConfiguration`](../Sources/ManifoldPersistenceSwiftData/ManifoldBootstrap.swift),
passed to `ManifoldBootstrap`. Because `ManifoldKit.quickStart()` takes no RAG
parameter, RAG uses the **manual bootstrap path** (`ManifoldBootstrap.build(...)`).
Once configured:

1. You call `bootstrap.ragService?.ingest(url:)` for each document. It parses,
   chunks, embeds (if an embedding backend is loaded), and persists the chunks.
2. Before every generation turn, `ConversationRuntime` calls the `RAGService`
   to retrieve the top-`k` passages for the user's message and injects them as a
   retrieval `PromptSlot`.
3. The assistant `ChatMessage` comes back with a `citations` array attached, and
   `ChatView` renders a "Sources" disclosure under the bubble for you.

There are two retrieval modes, picked automatically:

| Mode | When | Quality |
|------|------|---------|
| **Keyword fallback** | No embedding backend loaded (or it fails) | Case-insensitive substring match — useful with zero extra setup. |
| **Semantic** | An `EmbeddingBackend` is loaded | Cosine similarity over embeddings; optionally re-scored by a cross-encoder reranker. |

---

## 1. Add the dependency

Keyword-fallback RAG needs nothing beyond core — `ManifoldRuntime` and
`ManifoldPersistenceSwiftData` carry the whole pipeline. Semantic search needs
the on-device `LlamaEmbeddingBackend` from `ManifoldLlama`, which since v0.48
ships in the [`manifold-llama`](https://github.com/ManifoldKit/manifold-llama)
companion package:

```swift,no-build
dependencies: [
    .package(
        url: "https://github.com/ManifoldKit/ManifoldKit.git",
        from: "0.77.0" // x-release-please-version
    ),
    // Only needed for semantic search (§3) / reranking (§4) —
    // keyword-fallback RAG works with core alone.
    .package(url: "https://github.com/ManifoldKit/manifold-llama.git", from: "0.2.14"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "ManifoldKit", package: "ManifoldKit"),
        .product(name: "ManifoldLlama", package: "manifold-llama"),
    ]),
],
```

---

## 2. End-to-end: keyword RAG with zero extra models

This is the smallest working RAG app. It enables retrieval with no embedding
model — `RAGService` falls back to keyword search — so it runs anywhere the
default build runs. Swap in an embedding model ([§3](#3-add-semantic-search-with-an-embedding-model))
when you want semantic recall.

```swift
import Foundation
import ManifoldKit

@main
struct RAGExample {
    @MainActor
    static func main() async throws {
        // 1. Enable RAG. With no embedding backend, retrieval uses the
        //    case-insensitive keyword fallback.
        let ragConfiguration = RAGConfiguration()

        // 2. Manual bootstrap (quickStart() has no RAG parameter). Drain the
        //    progress stream, then await the built bootstrap.
        let (progress, task) = ManifoldBootstrap.build(
            configuration: ManifoldConfiguration(
                appName: "My RAG Chat",
                bundleIdentifier: "com.example.ragchat"
            ),
            ragConfiguration: ragConfiguration
        )
        for await _ in progress { /* drive a launch progress bar if you want */ }
        let bootstrap = try await task.value

        // 3. Register the compiled-in inference backends.
        for registrar in ManifoldKit.defaultBackendRegistrars {
            registrar.register(with: bootstrap.inferenceService)
        }

        // 4. Ingest documents. Parsing, chunking, and indexing happen here;
        //    `ingest` is idempotent per call and returns a DocumentRecord.
        let handbook = URL(fileURLWithPath: "/path/to/handbook.pdf")
        try await bootstrap.ragService?.ingest(url: handbook)

        // 5. Wire the chat view model. ConversationRuntime now retrieves the
        //    most relevant passages before each turn and attaches the matching
        //    citations to the assistant message automatically — no per-turn
        //    RAG code in your UI.
        let chatVM = ChatViewModel(
            inferenceService: bootstrap.inferenceService,
            conversationRuntime: bootstrap.conversationRuntime
        )
        chatVM.configure(bootstrap: bootstrap)
        _ = chatVM
    }
}
```

`ragService` is `nil` only when bootstrap could not resolve a vector-store URL
(a sandbox that denies the directory); the optional-chained `ingest` no-ops in
that case rather than crashing. Place the `ChatViewModel` in your SwiftUI
environment and present `ChatView` exactly as in the
[main quickstart](QUICKSTART.md#hello-world) — citations appear on their own.

---

## 3. Add semantic search with an embedding model

For real recall, load an embedding GGUF (e.g. `nomic-embed-text`,
`all-MiniLM-L6-v2`) into a `LlamaEmbeddingBackend` and hand it to
`RAGConfiguration`. Everything downstream is unchanged — the same `ingest` and
the same turn loop now embed text instead of keyword-matching.

```swift,no-build
import Foundation
import ManifoldKit
import ManifoldLlama   // LlamaEmbeddingBackend (from the manifold-llama companion package)

@MainActor
func makeRAGConfiguration() async throws -> RAGConfiguration {
    let embedder = LlamaEmbeddingBackend()
    try await embedder.loadModel(
        from: URL(fileURLWithPath: "/path/to/nomic-embed-text-v1.5.Q4_K_M.gguf")
    )

    return RAGConfiguration(
        embeddingBackend: embedder,
        chunkSize: 1800,     // characters per chunk (default)
        chunkOverlap: 200,   // overlap between chunks (default)
        topK: 5              // passages retrieved per turn (default)
    )
}
```

The embedding model must be loaded **before** you `ingest` documents you want
embedded — `ingest` embeds chunks at index time using whatever backend is
loaded. Documents ingested while no embedding backend was loaded remain
keyword-only until re-ingested. The vector index is persisted to
`<Application Support>/<bundleIdentifier>/ragvectors.bin` by default; override
with `RAGConfiguration(vectorStoreURL:)`.

---

## 4. Optional: cross-encoder reranking

Add a `LlamaReranker` loaded with a `bge-reranker`-class cross-encoder GGUF to
re-score the first-stage candidates against the query before injection. The
retriever widens its candidate pool, the reranker re-orders it, and the top
`topK` are kept. With no reranker (or one whose model is not loaded) retrieval
is byte-for-byte the non-reranked behaviour, including the keyword fallback.

```swift,no-build
import Foundation
import ManifoldKit
import ManifoldLlama   // LlamaEmbeddingBackend + LlamaReranker

@MainActor
func makeRerankedConfiguration() async throws -> RAGConfiguration {
    let embedder = LlamaEmbeddingBackend()
    try await embedder.loadModel(from: URL(fileURLWithPath: "/path/to/nomic-embed-text.gguf"))

    let reranker = LlamaReranker()
    try await reranker.loadModel(from: URL(fileURLWithPath: "/path/to/bge-reranker-base.gguf"))

    return RAGConfiguration(embeddingBackend: embedder, reranker: reranker)
}
```

---

## 5. Listing and managing documents in the UI

`ManifoldUIModelManagement` ships a document library surface. Construct a
`DocumentLibraryViewModel` (or use the sheet's convenience initialiser) with the
bootstrap's `ragService` and present `DocumentLibrarySheet` to let users add,
list, and delete indexed documents:

```swift,no-build
import SwiftUI
import ManifoldKit
import ManifoldUIModelManagement

struct DocumentsButton: View {
    let ragService: RAGService?
    @State private var showLibrary = false

    var body: some View {
        Button("Documents") { showLibrary = true }
            .sheet(isPresented: $showLibrary) {
                // `hasEmbeddingBackend` defaults to `nil`, in which case the sheet
                // derives the "Using keyword fallback" banner from
                // `RAGService.usesSemanticRetrieval` — pass an explicit `true`/`false`
                // only to override that derivation.
                DocumentLibrarySheet(ragService: ragService)
            }
    }
}
```

To drive ingestion yourself instead of through the sheet, call the
`RAGService` directly: `ingest(url:)`, `fetchDocuments()` (returns
`[DocumentRecord]`), and `deleteDocument(id:)`.

### Ingesting in-memory text

`ingest(url:)` requires a filesystem URL routed through a `DocumentParser`.
If your corpus is produced in-memory — generated scenes, transcript
fragments, anything that doesn't already live on disk — use
`ingest(text:documentID:title:)` instead. It shares the same chunk → embed →
persist pipeline as `ingest(url:)`, so retrieval and citation behaviour are
identical; you just skip writing (and cleaning up) a scratch file:

```swift,no-build
let record = try await bootstrap.ragService?.ingest(
    text: generatedScene.body,
    documentID: generatedScene.id,   // caller-owned ID — reuse it to delete later
    title: generatedScene.title
)
```

Pass your own stable `documentID` (rather than letting one get minted for
you) when you want `deleteDocument(id:)` to work against your own
caller-managed corpus, e.g. one document per generated scene.

---

## Citations

When retrieval returns hits, `ConversationRuntime` attaches a `[Citation]`
array to the assistant `ChatMessage`, and `ChatView` renders a collapsible
"Sources" disclosure beneath the bubble once streaming finishes. Each
[`Citation`](../Sources/ManifoldInference/Models/Citation.swift) carries the
source `documentTitle`, the `chunkIndex`, a truncated `snippet` preview, and a
relevance `score` (cosine similarity for semantic hits, `1.0` for keyword hits)
so you can sort or filter. If you build your own UI, render `message.citations`
with the shipped `CitationsView`, or read the array directly.

---

## Where to go next

- [`docs/RAG-TUNING.md`](RAG-TUNING.md) — tune chunk size/overlap, decide whether
  reranking earns its latency, and read the citation surface once setup works.
- [`docs/QUICKSTART.md`](QUICKSTART.md) — the full-stack `quickStart()` and
  `ManifoldBootstrap.build(...)` paths this guide extends.
- [`docs/SWIFTUI-MULTI-SESSION.md`](SWIFTUI-MULTI-SESSION.md) — pair RAG with a
  session sidebar and relaunch restore.
- [`docs/QUICKSTART-TOOLS.md`](QUICKSTART-TOOLS.md) — let the model call tools in
  addition to retrieving documents.
- [`docs/FeatureMatrix.md`](FeatureMatrix.md) — full backend → capability table.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `bootstrap.ragService` is `nil` | You didn't pass a `ragConfiguration:` to `ManifoldBootstrap`, or the vector-store directory couldn't be resolved (sandbox denial). Check the launch logs for the "RAG retrieval disabled" warning. |
| Retrieval returns nothing relevant | No embedding backend loaded → keyword-only mode. Load a `LlamaEmbeddingBackend` ([§3](#3-add-semantic-search-with-an-embedding-model)) and **re-ingest** so chunks get embedded. |
| `DocumentParserError.unsupportedFileType` from `ingest` | The file extension isn't one of the registered parsers (`.txt`, `.md`, `.pdf` by default). Pass custom `parsers:` to `RAGService` if you need more. |
| `RAGError.embeddingFailed` | The embedding backend threw while embedding a chunk or query (e.g. OOM on a very long input). Queries longer than `ManifoldConfiguration.shared.maxRAGQueryBytes` are truncated automatically; chunk size is bounded by `RAGConfiguration.chunkSize`. |
| Citations never appear | Retrieval returned zero above-zero-score hits, or no document was ingested. Confirm `ingest` completed and `fetchDocuments()` lists the file. |
