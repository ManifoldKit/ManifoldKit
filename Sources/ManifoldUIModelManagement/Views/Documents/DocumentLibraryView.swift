import SwiftUI
import UniformTypeIdentifiers
import os
import ManifoldRuntime
import ManifoldInference

/// Lists ingested RAG documents and lets the user add or remove them.
///
/// Reuses the host's ``RAGService`` actor (typically obtained from
/// ``ManifoldBootstrap/ragService``). Designed to live alongside the model
/// management UI — host apps can present it as a sheet from a sidebar
/// "Knowledge Base" button, or embed it in a settings tab.
///
/// Add flow: file picker (``allowedContentTypes`` is ``txt`` + ``pdf`` to
/// match the shipped ``DocumentParser`` set) and, on macOS, drag-and-drop
/// from Finder. Each ingest runs concurrently and surfaces a per-row spinner
/// while the parser + chunker run.
public struct DocumentLibraryView: View {

    @State private var viewModel: DocumentLibraryViewModel
    @State private var showImporter: Bool = false
    @State private var pendingDelete: DocumentRecord?
    @State private var isDropTargeted: Bool = false

    /// Document file types accepted by the importer. Mirrors the `parsers:`
    /// list passed to ``RAGService`` in ``ManifoldBootstrap`` — keep in sync
    /// when adding a new ``DocumentParser``.
    nonisolated private static let allowedContentTypes: [UTType] = [.plainText, .pdf]

    public init(viewModel: DocumentLibraryViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        // Split into separately type-checked subtrees — the monolithic `body`
        // expression previously took >200ms to type-check (see
        // -warn-long-function-bodies).
        baseContent
        .alert(
            "Delete Document",
            isPresented: isDeleteAlertPresented,
            presenting: pendingDelete
        ) { document in
            deleteAlertActions(for: document)
        } message: { document in
            Text("Remove \"\(document.title)\" from the knowledge base? Its chunks will be deleted from the vector index.")
        }
        .alert(
            "Document Library",
            isPresented: isErrorAlertPresented
        ) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .task {
            await viewModel.refresh()
        }
        #if os(macOS)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        #endif
    }

    private var baseContent: some View {
        Group {
            if viewModel.ragService == nil {
                disabledStateView
            } else {
                contentList
            }
        }
        .navigationTitle("Knowledge Base")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Label("Add Document", systemImage: "plus")
                }
                .disabled(viewModel.ragService == nil)
                .accessibilityIdentifier("document-library-add-button")
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: Self.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
    }

    @ViewBuilder
    private func deleteAlertActions(for document: DocumentRecord) -> some View {
        Button("Delete", role: .destructive) {
            Task { await viewModel.delete(document) }
            pendingDelete = nil
        }
        Button("Cancel", role: .cancel) {
            pendingDelete = nil
        }
    }

    // MARK: - Alert bindings

    private var isDeleteAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var isErrorAlertPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var contentList: some View {
        List {
            if !viewModel.hasEmbeddingBackend {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Using keyword fallback")
                                .font(.subheadline.weight(.semibold))
                            Text("RAG retrieval is running on case-insensitive keyword search. Configure an embedding model for semantic search.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityIdentifier("document-library-keyword-banner")
                }
            }

            Section {
                if viewModel.documents.isEmpty && viewModel.ingestingURLs.isEmpty {
                    emptyStateRow
                } else {
                    ForEach(viewModel.documents) { document in
                        DocumentRow(
                            document: document,
                            onDelete: { pendingDelete = document }
                        )
                    }

                    ForEach(Array(viewModel.ingestingURLs), id: \.self) { url in
                        IngestProgressRow(url: url)
                    }
                }
            } header: {
                if !viewModel.documents.isEmpty || !viewModel.ingestingURLs.isEmpty {
                    Text("Documents")
                }
            } footer: {
                Text("Add .txt or .pdf files. RAG runs automatically on each turn — retrieved passages appear as a \"Sources\" disclosure beneath the assistant's reply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .overlay {
            if viewModel.isLoading && viewModel.documents.isEmpty {
                ProgressView()
            }
        }
        #if os(macOS)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        #endif
    }

    private var emptyStateRow: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No documents yet")
                .font(.headline)
            Text("Add .txt or .pdf files to power retrieval-augmented chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityIdentifier("document-library-empty-state")
    }

    private var disabledStateView: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Knowledge Base Disabled")
                .font(.headline)
            Text("This app was bootstrapped without RAGConfiguration. Pass `ragConfiguration:` to ManifoldBootstrap to enable on-device retrieval.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Import handlers

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task { await viewModel.ingest(urls: urls) }
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let collectedLock = OSAllocatedUnfairLock(initialState: [URL]())
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, Self.allowedContentTypes.contains(where: { url.pathExtension.lowercased() == $0.preferredFilenameExtension }) {
                    collectedLock.withLock { $0.append(url) }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collectedLock.withLock { $0 }
            guard !urls.isEmpty else { return }
            Task { await viewModel.ingest(urls: urls) }
        }
        return true
    }
    #endif
}

// MARK: - DocumentRow

private struct DocumentRow: View {
    let document: DocumentRecord
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(document.fileType.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill.tertiary, in: Capsule())
                    Text("\(document.chunkCount) chunk\(document.chunkCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(document.indexedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(document.title)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(document.title), \(document.fileType.uppercased()), \(document.chunkCount) chunks")
    }

    private var iconName: String {
        switch document.fileType.lowercased() {
        case "pdf": return "doc.richtext"
        case "txt": return "doc.text"
        default: return "doc"
        }
    }
}

// MARK: - IngestProgressRow

private struct IngestProgressRow: View {
    let url: URL

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                Text("Parsing & indexing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ingesting \(url.lastPathComponent)")
    }
}

// MARK: - Preview

#Preview("Empty") {
    NavigationStack {
        DocumentLibraryView(
            viewModel: DocumentLibraryViewModel(ragService: nil)
        )
    }
}
