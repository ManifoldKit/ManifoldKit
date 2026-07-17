import SwiftUI
import ManifoldRuntime
import ManifoldInference
import ManifoldUI

/// Unified model management sheet combining model selection, download, and storage.
public struct ModelManagementSheet: View {

    @Environment(ModelManagementViewModel.self) private var managementViewModel
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var features: ManifoldConfiguration.Features { ManifoldConfiguration.shared.features }
    private var compiledBackends: CompiledBackends { .current }
    private let initialTab: Tab
    private let recommendedModelIDs: Set<String>?
    private let recommendationTitle: String?
    private let recommendationMessage: String?
    private let registrySource: RegistrySource

    public enum Tab: String, CaseIterable {
        case select = "Select"
        case download = "Download"
        case storage = "Storage"

        var systemImage: String {
            switch self {
            case .select: "checkmark.circle"
            case .download: "square.and.arrow.down"
            case .storage: "externaldrive"
            }
        }
    }

    /// Pure tab-availability rule, extracted from the instance method below so
    /// it can be exercised directly against constructed `Features` /
    /// `CompiledBackends` / `ModelRegistry` values instead of the ambient
    /// `ManifoldConfiguration.shared` / `CompiledBackends.current` globals.
    /// `internal` (not `public`) — this is a testing seam, not public API;
    /// `@testable import` reaches it from the gated suite.
    static func availableTabs(
        features: ManifoldConfiguration.Features,
        compiledBackends: CompiledBackends,
        modelRegistry: ModelRegistry
    ) -> [Tab] {
        var tabs: [Tab] = [.select]
        // Show the Download tab when the build can download AND a downloadable
        // backend is available. `compiledBackends.shouldPresentModelDownloads`
        // only reflects COMPILE-TIME backends (Foundation); it never sees the
        // MLX / llama.cpp families that hosts register at RUNTIME from the
        // companion packages (manifold-mlx / manifold-llama, #1749). Without the
        // runtime check the Download tab stays hidden for those hosts even with
        // a downloadable backend registered. `modelRegistry.compatibility(for:)`
        // reflects runtime registration (see InferenceService.compatibility).
        let runtimeDownloadable = modelRegistry.compatibility(for: .mlx).isSupported
            || modelRegistry.compatibility(for: .gguf).isSupported
        let canDownload = compiledBackends.shouldPresentModelDownloads || runtimeDownloadable
        if features.showModelDownload && compiledBackends.traits.contains(.huggingFace) && canDownload {
            tabs.append(.download)
        }
        if features.showStorageTab { tabs.append(.storage) }
        return tabs
    }

    private func availableTabs(for modelRegistry: ModelRegistry) -> [Tab] {
        Self.availableTabs(features: features, compiledBackends: compiledBackends, modelRegistry: modelRegistry)
    }

    @State private var selectedTab: Tab
    /// True while the first off-main directory scan is in flight. Surfaces a
    /// small ``ProgressView`` row so the sheet chrome can render immediately
    /// while the model list fills in asynchronously (#1774).
    @State private var isScanning = false

    /// Canonical init — pass the registry the host already constructed
    /// (typically `chatViewModel.modelRegistry`). The sheet works without
    /// reading `ChatViewModel` from the environment.
    public init(
        modelRegistry: ModelRegistry,
        initialTab: Tab = .select,
        recommendedModelIDs: Set<String>? = nil,
        recommendationTitle: String? = nil,
        recommendationMessage: String? = nil
    ) {
        self.registrySource = .explicit(modelRegistry)
        self.initialTab = initialTab
        self.recommendedModelIDs = recommendedModelIDs
        self.recommendationTitle = recommendationTitle
        self.recommendationMessage = recommendationMessage
        _selectedTab = State(initialValue: initialTab)
    }

    /// Deprecated environment-based init. Reads ``ChatViewModel`` from the
    /// SwiftUI environment and forwards to the registry-driven path.
    /// Pass `modelRegistry` explicitly instead.
    @available(*, deprecated, message: "Use ModelManagementSheet(modelRegistry:initialTab:recommendedModelIDs:recommendationTitle:recommendationMessage:) and pass chatViewModel.modelRegistry explicitly.")
    public init(
        initialTab: Tab = .select,
        recommendedModelIDs: Set<String>? = nil,
        recommendationTitle: String? = nil,
        recommendationMessage: String? = nil
    ) {
        self.registrySource = .environment
        self.initialTab = initialTab
        self.recommendedModelIDs = recommendedModelIDs
        self.recommendationTitle = recommendationTitle
        self.recommendationMessage = recommendationMessage
        _selectedTab = State(initialValue: initialTab)
    }

    private enum RegistrySource {
        case explicit(ModelRegistry)
        case environment
    }

    public var body: some View {
        switch registrySource {
        case .explicit(let registry):
            content(modelRegistry: registry)
        case .environment:
            EnvironmentBridge { registry in
                content(modelRegistry: registry)
            }
        }
    }

    @ViewBuilder
    private func content(modelRegistry: ModelRegistry) -> some View {
        NavigationStack {
            #if os(macOS)
            VStack(spacing: 0) {
                tabPickerBar(modelRegistry: modelRegistry)
                tabContent(modelRegistry: modelRegistry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(selectedTab.rawValue)
            .toolbar {
                doneToolbarItem
            }
            #else
            tabContent(modelRegistry: modelRegistry)
                .safeAreaInset(edge: .top, spacing: 0) { tabPickerBar(modelRegistry: modelRegistry) }
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle(selectedTab.rawValue)
                .toolbar {
                    doneToolbarItem
                }
            #endif
        }
        #if os(iOS)
        // On regular size class (iPad), allow a medium detent so the user can
        // switch models while keeping the split-view context partially visible.
        .presentationDetents(horizontalSizeClass == .regular ? [.medium, .large] : [.large])
        .presentationDragIndicator(.visible)
        #else
        // macOS sheets don't honor `.presentationDetents` and don't get a
        // useful intrinsic size from a `NavigationStack { VStack { List } }`
        // tree — without an explicit frame, the inner List collapses to zero
        // height and every tab renders blank below the picker. See #378.
        .frame(minWidth: 560, idealWidth: 720, minHeight: 480, idealHeight: 640)
        #endif
        .onAppear {
            // Tab selection is cheap and must apply synchronously so the chrome
            // renders correctly on first frame.
            if !availableTabs(for: modelRegistry).contains(selectedTab) {
                selectedTab = .select
            } else if selectedTab != initialTab {
                selectedTab = initialTab
            }
        }
        .task {
            // why: the GGUF/MLX directory scan is the ~2s main-thread stall in
            // #1774. `refreshAsync()` hops the scan off-main inside
            // `ModelStorageService.discoverModelsOffMain()`, so the sheet chrome
            // (tab picker, frame) paints immediately and only the model list
            // waits. `Task {}`/`.task` inherits @MainActor — the off-main hop
            // happens in the callee, never here. The cache is invalidated only
            // on real mutations (download/delete/import), so a re-appear with no
            // change keeps the cache.
            isScanning = true
            defer { isScanning = false }
            do {
                try await modelRegistry.refreshAsync()
            } catch {
                Log.download.warning("ModelManagementSheet: registry refresh on appear failed: \(error)")
            }
        }
    }

    /// Internal helper that pulls ``ChatViewModel`` from the environment so
    /// the deprecated `init()` overload can keep working without violating
    /// `@Environment` lookup rules (which require a `View` body site).
    private struct EnvironmentBridge<Content: View>: View {
        @Environment(ChatViewModel.self) private var chatViewModel
        let content: (ModelRegistry) -> Content

        var body: some View {
            content(chatViewModel.modelRegistry)
        }
    }

    private func tabPickerBar(modelRegistry: ModelRegistry) -> some View {
        VStack(spacing: 0) {
            tabPicker(modelRegistry: modelRegistry)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

            Divider()
                .accessibilityHidden(true)
        }
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var doneToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
    }

    @ViewBuilder
    private func tabPicker(modelRegistry: ModelRegistry) -> some View {
        let tabs = availableTabs(for: modelRegistry)
        if tabs.count > 1 {
            Picker("Section", selection: $selectedTab) {
                ForEach(tabs, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Model management section")
            .accessibilityIdentifier("model-management-tab-picker")
        }
    }

    @ViewBuilder
    private func tabContent(modelRegistry: ModelRegistry) -> some View {
        switch selectedTab {
        case .select:
            // Composes the public `ModelPicker` sample (formerly the private
            // `ModelSelectionTabView`). `grouped: false` preserves the sheet's
            // historical single flat-list layout — no behavior change.
            ModelPicker(modelRegistry: modelRegistry, grouped: false, onSelect: { dismiss() })
                // Lightweight affordance while the first off-main scan lands
                // (#1774); `availableModels` is @Observable, so the list itself
                // repaints automatically once the scan resolves.
                .overlay(alignment: .top) {
                    if isScanning && modelRegistry.availableModels.isEmpty {
                        scanningIndicator
                    }
                }
        case .download:
            HuggingFaceBrowserView(
                modelRegistry: modelRegistry,
                recommendedModelIDs: recommendedModelIDs,
                recommendationTitle: recommendationTitle,
                recommendationMessage: recommendationMessage
            )
        case .storage:
            LocalModelStorageView(modelRegistry: modelRegistry)
        }
    }

    private var scanningIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Scanning for models…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.bar, in: Capsule())
        .padding(.top, 8)
        .accessibilityIdentifier("model-management-scanning-indicator")
    }
}


#Preview {
    let chatVM = ChatViewModel()
    ModelManagementSheet(modelRegistry: chatVM.modelRegistry)
        .environment(ModelManagementViewModel())
}
