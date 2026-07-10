import Foundation
import ManifoldInference
import ManifoldRuntime
import ManifoldPersistenceSwiftData
// SampleDocumentCorpus stays in ManifoldTestSupport (no persistence
// dependency of its own) — see docs/plans/architecture-improvements-2026-07.md
// item 4.4 for the split rationale.
import ManifoldTestSupport

/// Assembles the **real** RAG stack for the Glass Box flagship research-session
/// demo / live path (#1575).
///
/// Where the scripted CI run uses keyword-fallback retrieval and a synthetic
/// memory record, this factory wires a genuine ``RAGConfiguration`` with a live
/// ``OllamaEmbeddingBackend`` (`nomic-embed-text`) so the demo retrieves real
/// passages from the bundled ``SampleDocumentCorpus``.
///
/// It is intentionally confined to the demo/live path: scripted-mode scenario
/// runs never construct this, so they do not require a live embedding model.
/// Hosts driving the flagship scenario interactively call
/// ``makeBootstrap(configuration:)`` to obtain a fully-wired, in-memory
/// ``ManifoldBootstrap`` whose ``ManifoldBootstrap/ragService`` already contains
/// the ingested corpus.
public enum GlassBoxDemoRAG {

    /// Builds a ``RAGConfiguration`` backed by a live Ollama embedding backend.
    ///
    /// - Parameters:
    ///   - baseURL: Ollama server URL. Defaults to `http://localhost:11434`.
    ///   - modelName: Embedding model. Defaults to
    ///     ``OllamaEmbeddingBackend/defaultModel`` (`nomic-embed-text`).
    public static func makeConfiguration(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        modelName: String = OllamaEmbeddingBackend.defaultModel
    ) -> RAGConfiguration {
        RAGConfiguration(
            embeddingBackend: OllamaEmbeddingBackend(baseURL: baseURL, modelName: modelName)
        )
    }

    /// Builds an in-memory ``ManifoldBootstrap`` with the demo RAG stack wired
    /// in and the bundled ``SampleDocumentCorpus`` already ingested.
    ///
    /// In-memory so the demo leaves nothing on disk. The returned bootstrap's
    /// ``ManifoldBootstrap/conversationRuntime`` queries the ingested corpus
    /// before each turn and attaches the resulting ``Citation`` list to the
    /// assistant message.
    ///
    /// - Throws: If the in-memory container cannot be built, or if document
    ///   ingestion (which calls the live embedding backend) fails — surfacing a
    ///   down/misconfigured Ollama server rather than silently degrading.
    @MainActor
    public static func makeBootstrap(
        configuration: ManifoldConfiguration,
        inferenceService: InferenceService? = nil,
        ragConfiguration: RAGConfiguration? = nil
    ) async throws -> ManifoldBootstrap {
        let bootstrap = try ManifoldBootstrap.makeInMemory(
            configuration: configuration,
            inferenceService: inferenceService,
            ragConfiguration: ragConfiguration ?? makeConfiguration()
        )
        if let ragService = bootstrap.ragService {
            for url in SampleDocumentCorpus.documentURLs() {
                _ = try await ragService.ingest(url: url)
            }
        }
        return bootstrap
    }
}
