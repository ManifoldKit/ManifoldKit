import Foundation
import Observation
import ManifoldRuntime
import ManifoldInference

/// View model for ``DocumentLibraryView``.
///
/// Owns the on-screen ``DocumentRecord`` list, drives ingestion through the
/// shared ``RAGService`` actor, and tracks per-URL ingest progress so the UI
/// can surface a per-file spinner. Stateless when ``ragService`` is `nil` —
/// the view shows an "RAG disabled" placeholder in that case.
@Observable
@MainActor
public final class DocumentLibraryViewModel {

    /// Hands-off ingestion + retrieval surface. `nil` when the host
    /// bootstrapped without ``RAGConfiguration``.
    public let ragService: RAGService?

    /// `true` when the active retrieval path uses an embedding backend.
    /// Drives the "Using keyword fallback" banner in the view — keyword
    /// fallback works but isn't obvious to users without this signal.
    ///
    /// Derived from ``RAGService/usesSemanticRetrieval`` when the caller
    /// doesn't pass an explicit override to ``init(ragService:hasEmbeddingBackend:)``
    /// — `ManifoldBootstrap` falls back to the bundled `NLEmbeddingBackend`
    /// (always loaded) when the host injects no embedding backend, so this
    /// must reflect the service's actual state rather than a caller-supplied
    /// constant that can silently disagree with it.
    public let hasEmbeddingBackend: Bool

    /// Current list of ingested documents, sorted newest-first.
    public private(set) var documents: [DocumentRecord] = []

    /// `true` while ``refresh()`` is fetching the document list.
    public private(set) var isLoading: Bool = false

    /// File URLs currently being ingested. Drives per-row spinners.
    public private(set) var ingestingURLs: Set<URL> = []

    /// Last user-facing error from ingest or delete. Cleared when set to `nil`.
    public var errorMessage: String?

    public init(ragService: RAGService?, hasEmbeddingBackend: Bool? = nil) {
        self.ragService = ragService
        self.hasEmbeddingBackend = hasEmbeddingBackend ?? (ragService?.usesSemanticRetrieval ?? false)
    }

    // MARK: - Refresh

    /// Reloads ``documents`` from the service. Called on view appear.
    public func refresh() async {
        guard let ragService else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let records = try await ragService.fetchDocuments()
            // Newest-first: matches the model-management list idiom.
            documents = records.sorted(by: { $0.indexedAt > $1.indexedAt })
        } catch {
            Log.persistence.warning("DocumentLibraryViewModel: refresh failed: \(error.localizedDescription)")
            errorMessage = "Failed to load documents: \(error.localizedDescription)"
        }
    }

    // MARK: - Ingest

    /// Ingests a list of file URLs concurrently. Each URL drives its own
    /// progress entry in ``ingestingURLs`` and refreshes the list once it
    /// completes — successful adds appear in real time as parsing finishes.
    public func ingest(urls: [URL]) async {
        guard let ragService else { return }
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                ingestingURLs.insert(url)
                group.addTask {
                    await self.ingestOne(url: url, service: ragService)
                }
            }
            await group.waitForAll()
        }
        await refresh()
    }

    private func ingestOne(url: URL, service: RAGService) async {
        defer { ingestingURLs.remove(url) }
        // Some macOS file pickers and drag drops hand back security-scoped
        // URLs. Start/stop accessing brackets the read so sandboxed builds
        // don't read-deny on the parser hop. No-op on iOS-bundled URLs.
        let scopeOK = url.startAccessingSecurityScopedResource()
        defer { if scopeOK { url.stopAccessingSecurityScopedResource() } }

        do {
            _ = try await service.ingest(url: url)
        } catch {
            Log.inference.warning("DocumentLibraryViewModel: ingest failed for \(url.lastPathComponent): \(error.localizedDescription)")
            errorMessage = "Failed to ingest \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Delete

    public func delete(_ document: DocumentRecord) async {
        guard let ragService else { return }
        do {
            try await ragService.deleteDocument(id: document.id)
            documents.removeAll { $0.id == document.id }
        } catch {
            Log.persistence.warning("DocumentLibraryViewModel: delete failed for \(document.title): \(error.localizedDescription)")
            errorMessage = "Failed to delete \(document.title): \(error.localizedDescription)"
        }
    }
}
