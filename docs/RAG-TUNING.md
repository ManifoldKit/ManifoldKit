# ManifoldKit RAG Tuning

**Audience:** consumer
**Status:** living

A reference for the *knobs* on ManifoldKit's on-device RAG pipeline — once you
have retrieval working end-to-end via [`QUICKSTART-RAG.md`](QUICKSTART-RAG.md),
this page explains how to trade recall against latency, size your chunks, decide
whether reranking earns its keep, and read the citation surface.

> **Read the quickstart first.** This guide assumes you already have a
> `RAGConfiguration` wired through `ManifoldBootstrap` and documents ingesting.
> It does not re-teach setup — it only adds tuning depth.

> **Honest scope.** ManifoldKit ships **one** sentence-aware chunker and a
> **dense-with-keyword-fallback** retriever — *not* a selectable "chunking
> strategy" menu or a configurable hybrid-fusion mode. The tuning surface below
> is exactly what the source exposes; everything else is editorialised away.

---

## The pipeline, and where each knob lives

```
ingest(url:)                         retrieve(query:limit:) / retrieveSlots
   │                                          │
   ├─ parse  (.txt / .md / .pdf)              ├─ truncate query to maxRAGQueryBytes
   ├─ chunk  (chunkSize, overlap)             ├─ embed query  ──(fail/no model)──┐
   └─ embed  (embeddingBackend, at index time)│                                  │
                                              ├─ vector search (top N candidates) │
                                              │     N = limit × 3 if reranker ready│
                                              ├─ rerank (reranker)  ◀─────────────┘
                                              └─ keep top `limit`, build [Citation]
                                                                    └─ keyword fallback
```

Every tunable property is on
[`RAGConfiguration`](../Sources/ManifoldPersistenceSwiftData/ManifoldBootstrap.swift)
(passed to `ManifoldBootstrap.build(...)`), except the query cap, which is a
process-global on `ManifoldConfiguration`.

| Knob | Type / default | Stage | What it trades |
|------|----------------|-------|----------------|
| `chunkSize` | `Int = 1800` (characters) | index | Larger = more context per hit, fewer hits, coarser citations |
| `chunkOverlap` | `Int = 200` (characters) | index | Higher = fewer answers split across a chunk boundary, more index bloat |
| `topK` | `Int = 5` | retrieve | More passages injected per turn → better recall, more prompt budget burned |
| `embeddingBackend` | `nil` | index + retrieve | Present → semantic search; absent → keyword fallback |
| `reranker` | `nil` | retrieve | Present + loaded → widen-then-rescore; absent → byte-for-byte non-reranked |
| `maxRAGQueryBytes` | `8_000` (bytes, on `ManifoldConfiguration`) | retrieve | Query truncation guard against OOM on a pathological input |

---

## 1. Chunk size and overlap

`DocumentChunker` is sentence-aware: it packs whole sentences up to `chunkSize`
characters, then starts the next chunk `chunkOverlap` characters back so an
answer that straddles a boundary still lands intact in at least one chunk.

```swift,no-build
RAGConfiguration(
    embeddingBackend: embedder,
    chunkSize: 1800,    // default — characters, not tokens
    chunkOverlap: 200   // default — ~11% of chunkSize
)
```

**How to choose:**

- **Smaller chunks (800–1200)** sharpen retrieval precision and produce tighter,
  more quotable citations — the snippet you show the user is closer to the
  matched passage. The cost is that a fact spread across several sentences can
  land in different chunks, so you may need a higher `topK` to reassemble it.
- **Larger chunks (2000–3000)** give the model more surrounding context per hit
  and tolerate sloppy queries, but dilute the embedding (the vector averages
  more text, so cosine similarity is noisier) and make citations coarse.
- **Overlap** earns its cost on prose with cross-sentence reasoning. Keep it
  around 10–15% of `chunkSize`. Pushing it higher inflates the index (every
  overlapped span is embedded and stored again) for diminishing recall.

`chunkSize` is in **characters, not tokens** — a rough rule of thumb is
~4 characters/token, so the default 1800 is roughly a 450-token passage. Budget
`topK × chunkSize / 4` tokens of prompt headroom for retrieval and confirm it
fits under your model's context window minus the system prompt and history.

> Chunking happens at **index time**. Changing `chunkSize`/`chunkOverlap` only
> affects documents ingested *after* the change — re-ingest to re-chunk.

---

## 2. Dense (semantic) vs. keyword fallback

There is no "hybrid mode" switch. Retrieval picks its path automatically:

| Path | When | Behaviour |
|------|------|-----------|
| **Semantic (dense)** | An `EmbeddingBackend` is loaded | Cosine similarity over chunk embeddings |
| **Keyword fallback** | No embedding backend, **or** the embedder throws (e.g. OOM) | Case-insensitive substring match; every hit scored `1.0` |

The fallback is a *degradation*, not a parallel mode you fuse with the dense
results — when the embedding backend fails on a query, `retrieve` catches it and
falls through to keyword search rather than returning nothing. This means RAG
"works" with zero models loaded (handy for tests and first-run), but recall is
substring-only until you load an embedder and **re-ingest** so chunks get
embedded.

**Implications for tuning:**

- Documents ingested while no embedder was loaded are keyword-only forever (no
  stored vector). Re-ingest after loading the embedder.
- Because keyword hits all score `1.0`, you cannot threshold or rank them by
  relevance — if you sort citations by `score`, keyword results tie. Treat the
  fallback as a coarse safety net, not a tuning target.

---

## 3. Reranking: latency vs. recall

A cross-encoder reranker (e.g. a `bge-reranker`-class GGUF behind
`ManifoldLlama`'s `LlamaReranker`) scores each *(query, candidate)* pair jointly
instead of comparing pre-computed vectors. It is strictly more accurate than
cosine similarity — and strictly more expensive, because it runs a forward pass
per candidate.

ManifoldKit's reranking is a **widen-then-rescore**:

1. When a reranker reports `isReady == true`, the retriever widens its
   first-stage candidate pool to `limit × 3`
   (`RAGService.rerankCandidateMultiplier = 3`).
2. The reranker re-scores those candidates against the query.
3. The top `limit` survive and become the injected passages + citations.

```swift,no-build
RAGConfiguration(
    embeddingBackend: embedder,
    reranker: reranker   // LlamaReranker, from manifold-llama
)
```

**The tradeoff to reason about:**

- **Recall.** The reranker can only re-order what first-stage retrieval surfaced.
  The `× 3` widening is what gives it room to *rescue* a relevant chunk that
  cosine similarity ranked just outside `topK`. With `topK = 5`, the reranker
  sees 15 candidates and promotes the best 5 — so the recall win comes from the
  widened pool, not the reranker alone.
- **Latency.** Cost scales with the **widened** pool, not `topK`: roughly
  `topK × 3` cross-encoder forward passes per turn, on the critical path before
  the first token. A larger `topK` multiplies this — `topK = 10` reranks 30
  candidates. If reranking pushes time-to-first-token past your budget, lower
  `topK` before dropping the reranker entirely.
- **Graceful degrade.** With no reranker, or one whose model is not loaded
  (`isReady == false`, e.g. `PassthroughReranker`), retrieval is **byte-for-byte
  the non-reranked behaviour**, including the keyword fallback. You can ship the
  reranker config and let it no-op on devices that can't afford the model.

**When reranking is worth it:** large or noisy corpora where the right passage
is frequently *near* the top but not *at* it. **When to skip it:** small
hand-curated corpora where dense `topK = 5` already returns the right chunk —
you pay the latency for no recall gain.

---

## 4. The query-size cap

Before embedding or keyword-matching, the query is truncated to
`ManifoldConfiguration.shared.maxRAGQueryBytes` (default **8,000 bytes**) of its
UTF-8 prefix. This is an OOM guard for pathological inputs (a user pasting a
whole document into the box), not a relevance knob — but if you embed an
unusually long retrieval query and recall feels off, confirm it isn't being
silently truncated. Raise the cap only if your embedder handles longer inputs
without memory pressure.

---

## 5. Reading the citation surface

Every retrieved passage produces a
[`Citation`](../Sources/ManifoldInference/Models/Citation.swift) attached to the
assistant `ChatMessage`:

```swift,no-build
public struct Citation {
    public let documentID: UUID
    public let documentTitle: String
    public let chunkIndex: Int      // which chunk within the document
    public let snippet: String      // truncated preview, ≤ 240 chars
    public let score: Float         // cosine similarity (semantic) or 1.0 (keyword)
}
```

- **`snippet`** is truncated to `Citation.snippetCharacterLimit` (240
  characters) at construction — it is a preview, not the full chunk text. Don't
  rely on it for re-retrieval; use `documentID` + `chunkIndex` to fetch the
  source.
- **`score`** lets you sort or filter in a custom UI. Remember that **keyword
  hits all score `1.0`**, so a score-based threshold only discriminates in
  semantic mode.
- The shipped `ChatView` renders these as a collapsible "Sources" disclosure
  automatically; bring-your-own-UI hosts read `message.citations` and render
  `CitationsView` (or their own).

Tighter chunks → tighter, more quotable snippets. This is the second-order
reason to prefer smaller `chunkSize` for user-facing citation quality even when
recall doesn't demand it.

---

## Tuning checklist

1. **Start at defaults** (`chunkSize 1800`, `overlap 200`, `topK 5`, no
   reranker) with an embedding model loaded. Re-ingest after loading the
   embedder.
2. **If answers miss context that's clearly in the docs:** raise `topK` first
   (cheap), then `chunkOverlap` if facts straddle boundaries.
3. **If citations are too coarse / off-topic:** lower `chunkSize` and re-ingest.
4. **If the right passage is near-but-not-top:** add a reranker — the `× 3`
   widening is the recall lever.
5. **If time-to-first-token regresses after adding a reranker:** lower `topK`
   (you rerank `topK × 3` candidates) before removing the reranker.
6. **Mind the prompt budget:** `topK × chunkSize / 4 ≈ injected tokens`. Keep it
   under context − system prompt − history.

---

## See also

- [`QUICKSTART-RAG.md`](QUICKSTART-RAG.md) — end-to-end setup this guide extends.
- [`FeatureMatrix.md`](FeatureMatrix.md) — backend → capability table (which
  backends provide embeddings / reranking).
