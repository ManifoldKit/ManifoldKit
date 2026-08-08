import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// Modal sheet wrapper for ``DocumentLibraryView``.
///
/// Provides the chrome the bare ``DocumentLibraryView`` doesn't carry —
/// `NavigationStack`, "Done" toolbar item, and platform-appropriate sizing —
/// so a host app can present it with a one-line `.sheet { }` modifier.
public struct DocumentLibrarySheet: View {

    @Environment(\.dismiss) private var dismiss

    private let viewModel: DocumentLibraryViewModel

    public init(viewModel: DocumentLibraryViewModel) {
        self.viewModel = viewModel
    }

    /// Convenience overload that builds the view model from a ``RAGService``
    /// reference. `hasEmbeddingBackend` defaults to `nil`, in which case
    /// ``DocumentLibraryViewModel`` derives it from
    /// ``RAGService/usesSemanticRetrieval`` — pass an explicit value only to
    /// override that derivation (e.g. a host that knows something the
    /// service's live state doesn't yet reflect).
    public init(ragService: RAGService?, hasEmbeddingBackend: Bool? = nil) {
        self.viewModel = DocumentLibraryViewModel(
            ragService: ragService,
            hasEmbeddingBackend: hasEmbeddingBackend
        )
    }

    public var body: some View {
        NavigationStack {
            DocumentLibraryView(viewModel: viewModel)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 720, minHeight: 480, idealHeight: 640)
        #endif
    }
}
