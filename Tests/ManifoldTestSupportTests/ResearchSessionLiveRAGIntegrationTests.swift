@preconcurrency import XCTest
import Foundation
import SwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldTestSupport
import ManifoldContractTestSupport

/// Live integration coverage for the Glass Box flagship research-session
/// scenario wired against the **real** RAG stack (#1575).
///
/// Unlike `RuntimeScenarioRunnerTests`, which run the scenario in hermetic
/// scripted mode with a synthetic fixed-count compression policy, this suite:
///
/// 1. Ingests the bundled `SampleDocumentCorpus` into a real `RAGService`
///    (in-memory `SwiftDataDocumentStore` + on-disk `FlatFileVectorStore`)
///    backed by a real `OllamaEmbeddingBackend` (`nomic-embed-text`).
/// 2. Runs the scenario in scripted-turn mode but with the real RAG service and
///    a context-window pre-turn compression policy wired into the runtime, so
///    retrieval and compression exercise the genuine path.
/// 3. Asserts structurally that at least one assistant message carries a
///    `Citation`, and that compression fired at least once.
///
/// It is **local-only**: gated on a reachable Ollama server with the embedding
/// model installed via `XCTSkipUnless`, matching the `OllamaToolCallingE2ETests`
/// pattern. CI without Ollama skips cleanly — the default `swift test` lane
/// never requires a live model.
@MainActor
final class ResearchSessionLiveRAGIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var vectorURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            HardwareRequirements.hasOllamaServer,
            "Ollama server not running at localhost:11434 — live RAG test skipped."
        )
        let installed = HardwareRequirements.listOllamaModels() ?? []
        try XCTSkipUnless(
            installed.contains(where: { $0.contains(OllamaEmbeddingBackend.defaultModel) }),
            "Embedding model '\(OllamaEmbeddingBackend.defaultModel)' not installed in Ollama. Installed: \(installed)"
        )
        container = try ModelContainerFactory.makeInMemoryContainer()
        vectorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
    }

    override func tearDown() {
        if let vectorURL { try? FileManager.default.removeItem(at: vectorURL) }
        container = nil
        vectorURL = nil
        super.tearDown()
    }

    /// Builds the real RAG service over the in-memory document store, on-disk
    /// vector index, and a live Ollama embedding backend, then ingests the
    /// bundled sample corpus.
    private func makeIngestedRAGService() async throws -> RAGService {
        let documentStore = SwiftDataDocumentStore(modelContext: container.mainContext)
        let vectorStore = FlatFileVectorStore(storageURL: vectorURL)
        let service = RAGService(
            documentStore: documentStore,
            vectorStore: vectorStore,
            embeddingBackend: OllamaEmbeddingBackend()
        )

        let urls = SampleDocumentCorpus.documentURLs()
        XCTAssertFalse(urls.isEmpty, "Sample document corpus must bundle at least one document.")
        for url in urls {
            _ = try await service.ingest(url: url)
        }
        return service
    }

    /// The flagship scenario, run against the real retrieval stack, must attach
    /// at least one `Citation` to an assistant message (structural, not
    /// content-based) and fire pre-turn compression at least once against the
    /// real context window.
    func test_researchSession_attachesCitation_andCompressesAgainstRealWindow() async throws {
        let rag = try await makeIngestedRAGService()

        // A context-window policy keyed off real prompt-token usage. The
        // scripted backend reports no usage, so it falls back to the
        // message-count trigger — but the *policy* is the real window-pressure
        // one, not the scenario's deterministic fixed-count policy.
        let compression = ContextWindowPreTurnCompressionPolicy(
            contextWindow: 512,            // simulator/CI context cap
            triggerFraction: 0.5,
            messageCountFallback: 4
        )

        let result = try await RuntimeScenarioRunner.run(
            .researchSession,
            mode: .scripted,
            ragService: rag,
            preTurnCompressionPolicy: compression
        )

        // Structural subsequence (historyCompressed → contextAssembled → ...).
        XCTAssertTrue(
            result.subsequencePassed,
            result.subsequenceFailureReason ?? "subsequence check failed"
        )

        // Deliverable 3: at least one assistant message carries a Citation.
        let assistantCitationCount = result.producedMessages
            .filter { $0.role == .assistant }
            .compactMap { $0.citations?.count }
            .reduce(0, +)
        XCTAssertGreaterThanOrEqual(
            assistantCitationCount, 1,
            "Live RAG run must attach at least one Citation to an assistant message. Messages: \(result.producedMessages.map { "\($0.role):\($0.citations?.count ?? 0)" })"
        )

        // Deliverable 4: pre-turn compression fired at least once.
        let compressionCount = result.trace.kinds.filter { $0 == .historyCompressed }.count
        XCTAssertGreaterThanOrEqual(
            compressionCount, 1,
            "Expected pre-turn compression to fire at least once; got \(compressionCount)."
        )
    }
}
