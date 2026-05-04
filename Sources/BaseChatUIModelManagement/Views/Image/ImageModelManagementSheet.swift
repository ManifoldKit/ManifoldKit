#if HuggingFace
import SwiftUI
import BaseChatInference
import BaseChatHuggingFace

/// Sheet wrapper around ``ImageModelInstallView`` for hosts that want to
/// present the install flow as a modal (settings menu, first-run prompt,
/// "Install your first image model" empty state, etc.).
///
/// Sibling to ``ModelManagementSheet`` for text models. Deliberately separate
/// — the text and image stacks have different identifier types
/// (`ModelInfo` vs ``ImageModelInfo``) and different lifecycles, and the
/// catalog here is a curated short-list rather than a Hub browser.
public struct ImageModelManagementSheet: View {

    @Environment(\.dismiss) private var dismiss

    private let huggingFaceService: HuggingFaceService
    private let storageRoot: URL?
    private let catalog: [DiffusionModelCatalogEntry]
    private let onInstalled: (ImageModelInfo) -> Void

    public init(
        huggingFaceService: HuggingFaceService,
        storageRoot: URL? = nil,
        catalog: [DiffusionModelCatalogEntry] = DiffusionModelCatalog.curated,
        onInstalled: @escaping (ImageModelInfo) -> Void
    ) {
        self.huggingFaceService = huggingFaceService
        self.storageRoot = storageRoot
        self.catalog = catalog
        self.onInstalled = onInstalled
    }

    public var body: some View {
        NavigationStack {
            ImageModelInstallView(
                huggingFaceService: huggingFaceService,
                storageRoot: storageRoot,
                catalog: catalog,
                onInstalled: onInstalled
            )
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("Image Models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        // Match `ModelManagementSheet` — without an explicit frame the inner
        // List collapses to zero height on macOS sheets.
        .frame(minWidth: 560, idealWidth: 720, minHeight: 480, idealHeight: 640)
        #endif
    }
}
#endif
