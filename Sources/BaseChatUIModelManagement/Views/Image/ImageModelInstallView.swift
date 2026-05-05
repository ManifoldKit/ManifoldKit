#if HuggingFace
import SwiftUI
import BaseChatInference
import BaseChatHuggingFace

/// First-run install UI for image-generation models.
///
/// Renders the curated ``DiffusionModelCatalog`` and drives
/// ``HuggingFaceService/downloadDiffusionModel(from:to:displayName:urlSession:progress:)``
/// per-row. On success, the resulting ``ImageModelInfo`` is handed back to
/// the host via ``onInstalled`` — typically the host feeds it to
/// `ImageGenerationService.loadModel(_:)`. Sibling to the existing text-model
/// browser; deliberately separate so the closed `ModelType` switches stay
/// untouched.
@MainActor
public struct ImageModelInstallView: View {

    private let huggingFaceService: HuggingFaceService
    private let onInstalled: (ImageModelInfo) -> Void
    private let catalog: [DiffusionModelCatalogEntry]
    private let storageRoot: URL

    @State private var installingID: String? = nil
    @State private var progress: Double = 0
    @State private var rowError: [String: String] = [:]
    @State private var installedModels: [String: ImageModelInfo] = [:]

    /// Creates the install view.
    ///
    /// - Parameters:
    ///   - huggingFaceService: The service that performs the diffusion download.
    ///   - storageRoot: Directory under which each model gets its own
    ///     subdirectory. Defaults to
    ///     `<ModelStorageService.modelsDirectory>/ImageModels`.
    ///   - catalog: The list of installable models. Defaults to
    ///     ``DiffusionModelCatalog/curated``.
    ///   - onInstalled: Called on the main actor with the resulting
    ///     ``ImageModelInfo`` once a download finishes successfully.
    public init(
        huggingFaceService: HuggingFaceService,
        storageRoot: URL? = nil,
        catalog: [DiffusionModelCatalogEntry] = DiffusionModelCatalog.curated,
        onInstalled: @escaping (ImageModelInfo) -> Void
    ) {
        self.huggingFaceService = huggingFaceService
        self.catalog = catalog
        self.onInstalled = onInstalled
        // Sit alongside the text-model `Models/` directory under a sibling
        // `ImageModels/` namespace, so storage accounting and cleanup are
        // straightforward.
        if let storageRoot {
            self.storageRoot = storageRoot
        } else {
            self.storageRoot = ModelStorageService()
                .modelsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("ImageModels", isDirectory: true)
        }
    }

    public var body: some View {
        List {
            Section {
                ForEach(catalog) { entry in
                    row(for: entry)
                }
            } header: {
                Text("Available image models")
            } footer: {
                Text("Models download from HuggingFace and are stored in your app's data directory.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("image-model-install-list")
        .onAppear {
            refreshInstalledModels()
        }
    }

    @ViewBuilder
    private func row(for entry: DiffusionModelCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayName)
                        .font(.headline)
                    Text(entry.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(entry.approximateSizeFormatted)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                installButton(for: entry)
            }

            if installingID == entry.id {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("image-model-install-progress-\(entry.id)")
            }
            if let message = rowError[entry.id] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("image-model-install-error-\(entry.id)")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func installButton(for entry: DiffusionModelCatalogEntry) -> some View {
        if installedModels[entry.id] != nil {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
                .accessibilityIdentifier("image-model-installed-\(entry.id)")
        } else if installingID == entry.id {
            ProgressView()
                .controlSize(.small)
        } else {
            Button {
                Task { await install(entry) }
            } label: {
                Text("Install")
            }
            .buttonStyle(.borderedProminent)
            .disabled(installingID != nil)
            .accessibilityIdentifier("image-model-install-button-\(entry.id)")
        }
    }

    private func install(_ entry: DiffusionModelCatalogEntry) async {
        installingID = entry.id
        progress = 0
        rowError[entry.id] = nil

        let destination = storageRoot.appendingPathComponent(
            slug(for: entry.id),
            isDirectory: true
        )

        do {
            let info = try await huggingFaceService.downloadDiffusionModel(
                from: entry.id,
                to: destination,
                displayName: entry.displayName,
                progress: { snapshot in
                    Task { @MainActor in
                        progress = snapshot.fractionCompleted
                    }
                }
            )
            installedModels[entry.id] = info
            installingID = nil
            progress = 0
            onInstalled(info)
        } catch {
            rowError[entry.id] = error.localizedDescription
            installingID = nil
            progress = 0
        }
    }

    /// Slugifies a HuggingFace repo ID (`"stabilityai/sdxl-turbo"`) into a
    /// single safe directory name (`"stabilityai__sdxl-turbo"`). Keeps the
    /// `org/name` distinction so two repos that happen to share a basename
    /// don't collide on disk.
    private func slug(for repoID: String) -> String {
        repoID.replacingOccurrences(of: "/", with: "__")
    }

    private func refreshInstalledModels() {
        let discovered = ModelStorageService(baseDirectory: storageRoot)
            .discoverImageModels()
        installedModels = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
    }
}
#endif
