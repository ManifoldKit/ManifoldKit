import SwiftUI
import BaseChatCore
import BaseChatInference
import BaseChatUI

/// Unified model management sheet combining model selection, download, and storage.
public struct ModelManagementSheet: View {

    @Environment(ChatViewModel.self) private var chatViewModel
    @Environment(ModelManagementViewModel.self) private var managementViewModel
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var features: BaseChatConfiguration.Features { BaseChatConfiguration.shared.features }
    private var compiledBackends: CompiledBackends { .current }
    private let initialTab: Tab
    private let recommendedModelIDs: Set<String>?
    private let recommendationTitle: String?
    private let recommendationMessage: String?

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

    public init(
        initialTab: Tab = .select,
        recommendedModelIDs: Set<String>? = nil,
        recommendationTitle: String? = nil,
        recommendationMessage: String? = nil
    ) {
        self.initialTab = initialTab
        self.recommendedModelIDs = recommendedModelIDs
        self.recommendationTitle = recommendationTitle
        self.recommendationMessage = recommendationMessage
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        NavigationStack {
            #if os(macOS)
            VStack(spacing: 0) {
                tabPickerBar
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(selectedTab.rawValue)
            .toolbar {
                doneToolbarItem
            }
            #else
            tabContent
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
            chatViewModel.refreshModels()
            managementViewModel.invalidateModelCache()
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
    private var tabContent: some View {
        switch selectedTab {
        case .select:
            ModelSelectionTabView(onSelect: { dismiss() })
        case .download:
            HuggingFaceBrowserView(
                recommendedModelIDs: recommendedModelIDs,
                recommendationTitle: recommendationTitle,
                recommendationMessage: recommendationMessage
            )
        case .storage:
            LocalModelStorageView()
        }
    }
}


#Preview {
    ModelManagementSheet()
        .environment(ChatViewModel())
        .environment(ModelManagementViewModel())
}
