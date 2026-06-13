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

    private var availableTabs: [Tab] {
        var tabs: [Tab] = [.select]
        if features.showModelDownload && compiledBackends.shouldPresentModelDownloads { tabs.append(.download) }
        if features.showStorageTab { tabs.append(.storage) }
        return tabs
    }

    @State private var selectedTab: Tab

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
                tabPickerBar
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
                .safeAreaInset(edge: .top, spacing: 0) { tabPickerBar }
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
            if !availableTabs.contains(selectedTab) {
                selectedTab = .select
            } else if selectedTab != initialTab {
                selectedTab = initialTab
            }
            do {
                try modelRegistry.refresh()
            } catch {
                Log.download.warning("ModelManagementSheet: registry refresh on appear failed: \(error)")
            }
            // why: do NOT blanket-invalidate the discovery cache here. The old
            // unconditional invalidateModelCache() forced a full synchronous GGUF
            // rescan on every sheet open (~2s main-thread stall, #1774). The cache
            // is now invalidated only on real mutations — download completion
            // (startDownloadSync), delete (deleteModel), and import (importModel) —
            // so a re-appear with no change keeps the cache. Deferred follow-up:
            // move discoverModels() off the main thread so even the first scan
            // doesn't stall.
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

    private var tabPickerBar: some View {
        VStack(spacing: 0) {
            tabPicker
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
    private var tabPicker: some View {
        let tabs = availableTabs
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
            ModelSelectionTabView(modelRegistry: modelRegistry, onSelect: { dismiss() })
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
}


#Preview {
    let chatVM = ChatViewModel()
    ModelManagementSheet(modelRegistry: chatVM.modelRegistry)
        .environment(ModelManagementViewModel())
}
