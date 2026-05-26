import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// The main chat view, displayed in the detail area of the app's navigation structure.
///
/// Shows a scrolling message history with auto-scroll, an input bar at the
/// bottom, and toolbar actions for device info, settings, and clearing the chat.
///
/// `APIConfig` is the type of the host-supplied API configuration view, which
/// `ChatView` presents as a sheet/popover when the user triggers the API key
/// recovery flow. Callers typically pass `{ APIConfigurationView() }` from
/// `ManifoldUIModelManagement`. The closure-injection keeps `ManifoldUI` free
/// of any back-edge to the model-management module.
public struct ChatView<APIConfig: View>: View {

    @Environment(ChatViewModel.self) private var viewModel

    private var features: ManifoldConfiguration.Features { ManifoldConfiguration.shared.features }

    /// Controls the model management sheet. Passed in from the host app so that the
    /// "Browse Models" button in the empty state can open it directly.
    @Binding public var showModelManagement: Bool

    @State private var isDeviceInfoExpanded: Bool = false
    @State private var isSettingsPresented: Bool = false
    @State private var isExportPresented: Bool = false
    @State private var showClearConfirmation: Bool = false
    @State private var showAPIConfiguration: Bool = false

    /// Optional replacement for the built-in "Send a message to start chatting."
    /// placeholder shown when the session has no messages. Hosts pass a custom
    /// view here to surface a flagship prompt button, first-run hints, etc.
    private let customEmptyPlaceholder: AnyView?

    /// Builder for the API configuration view. Held as a closure (rather than the
    /// pre-built view) so that any `@Environment` / `@Bindable` lookups inside
    /// `APIConfigurationView` resolve at sheet/popover presentation time, not at
    /// `ChatView` init.
    private let apiConfigurationBuilder: () -> APIConfig

    /// Optional host-supplied accessory rendered above the stock composer.
    /// This is the integration seam for add-ons such as voice capture without
    /// forcing `ManifoldUI` to depend on optional sibling modules.
    private let composerAccessoryBuilder: (() -> AnyView)?

    /// Optional opt-in metadata provider for URL preview cards in messages.
    ///
    /// The default is `nil`: `ManifoldUI` performs no network fetching and
    /// renders no link previews unless a host supplies this closure.
    private let linkPreviewProvider: LinkPreviewProvider?

    /// Builder for extra per-message context-menu items rendered after the
    /// built-in actions (pin, copy, edit, regenerate, branch, delete).
    /// Defaults to `nil`, in which case only the built-in items appear.
    /// The closure is invoked per message so hosts can vary items by role
    /// or content.
    private let contextMenuItemsBuilder: ((ChatMessageRecord) -> AnyView)?

    /// Optional renderer for non-user-visible kind records. By default these are hidden.
    /// Hosts supply this to render memory bubbles, annotation labels, or other internal records.
    private let customKindRenderer: ((ChatMessageRecord) -> AnyView)?

    public init(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) {
        self._showModelManagement = showModelManagement
        self.customEmptyPlaceholder = nil
        self.apiConfigurationBuilder = apiConfiguration
        self.composerAccessoryBuilder = nil
        self.linkPreviewProvider = linkPreviewProvider
        self.contextMenuItemsBuilder = nil
        self.customKindRenderer = nil
    }

    public init<ComposerAccessory: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder composerAccessory: @escaping () -> ComposerAccessory,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) {
        self._showModelManagement = showModelManagement
        self.customEmptyPlaceholder = nil
        self.apiConfigurationBuilder = apiConfiguration
        self.composerAccessoryBuilder = { AnyView(composerAccessory()) }
        self.linkPreviewProvider = linkPreviewProvider
        self.contextMenuItemsBuilder = nil
        self.customKindRenderer = nil
    }

    /// Creates a ``ChatView`` with a host-supplied empty-state view rendered
    /// when the active session has no messages.
    ///
    /// Use this overload to surface a curated prompt button, a first-run
    /// tour, or any other call-to-action in place of the default placeholder.
    public init<EmptyContent: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder emptyState: () -> EmptyContent,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) {
        self._showModelManagement = showModelManagement
        self.customEmptyPlaceholder = AnyView(emptyState())
        self.apiConfigurationBuilder = apiConfiguration
        self.composerAccessoryBuilder = nil
        self.linkPreviewProvider = linkPreviewProvider
        self.contextMenuItemsBuilder = nil
        self.customKindRenderer = nil
    }

    public init<EmptyContent: View, ComposerAccessory: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder emptyState: () -> EmptyContent,
        @ViewBuilder composerAccessory: @escaping () -> ComposerAccessory,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) {
        self._showModelManagement = showModelManagement
        self.customEmptyPlaceholder = AnyView(emptyState())
        self.apiConfigurationBuilder = apiConfiguration
        self.composerAccessoryBuilder = { AnyView(composerAccessory()) }
        self.linkPreviewProvider = linkPreviewProvider
        self.contextMenuItemsBuilder = nil
        self.customKindRenderer = nil
    }

    /// Creates a ``ChatView`` with host-supplied extra items appended to each
    /// message's context menu.
    ///
    /// The `contextMenuItems` closure is invoked per ``ChatMessageRecord``;
    /// items it returns render after the built-in pin/copy/edit/regenerate/
    /// branch/delete actions. Use this overload to add app-specific actions
    /// such as "Reply", "Translate", or "Send to…" without forking the
    /// stock message bubble.
    public init<ExtraItems: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder contextMenuItems: @escaping (ChatMessageRecord) -> ExtraItems,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) {
        self._showModelManagement = showModelManagement
        self.customEmptyPlaceholder = nil
        self.apiConfigurationBuilder = apiConfiguration
        self.composerAccessoryBuilder = nil
        self.linkPreviewProvider = linkPreviewProvider
        self.contextMenuItemsBuilder = { message in AnyView(contextMenuItems(message)) }
        self.customKindRenderer = nil
    }

    public init<ExtraItems: View, ComposerAccessory: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder contextMenuItems: @escaping (ChatMessageRecord) -> ExtraItems,
        @ViewBuilder composerAccessory: @escaping () -> ComposerAccessory,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) {
        self._showModelManagement = showModelManagement
        self.customEmptyPlaceholder = nil
        self.apiConfigurationBuilder = apiConfiguration
        self.composerAccessoryBuilder = { AnyView(composerAccessory()) }
        self.linkPreviewProvider = linkPreviewProvider
        self.contextMenuItemsBuilder = { message in AnyView(contextMenuItems(message)) }
        self.customKindRenderer = nil
    }

    public init<EmptyContent: View, ExtraItems: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder emptyState: () -> EmptyContent,
        @ViewBuilder contextMenuItems: @escaping (ChatMessageRecord) -> ExtraItems,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) {
        self._showModelManagement = showModelManagement
        self.customEmptyPlaceholder = AnyView(emptyState())
        self.apiConfigurationBuilder = apiConfiguration
        self.composerAccessoryBuilder = nil
        self.linkPreviewProvider = linkPreviewProvider
        self.contextMenuItemsBuilder = { message in AnyView(contextMenuItems(message)) }
        self.customKindRenderer = nil
    }

    public init<EmptyContent: View, ExtraItems: View, ComposerAccessory: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder emptyState: () -> EmptyContent,
        @ViewBuilder contextMenuItems: @escaping (ChatMessageRecord) -> ExtraItems,
        @ViewBuilder composerAccessory: @escaping () -> ComposerAccessory,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) {
        self._showModelManagement = showModelManagement
        self.customEmptyPlaceholder = AnyView(emptyState())
        self.apiConfigurationBuilder = apiConfiguration
        self.composerAccessoryBuilder = { AnyView(composerAccessory()) }
        self.linkPreviewProvider = linkPreviewProvider
        self.contextMenuItemsBuilder = { message in AnyView(contextMenuItems(message)) }
        self.customKindRenderer = nil
    }

    /// Creates a ``ChatView`` with a ``customKindRenderer`` for non-user-visible records.
    ///
    /// By default, records with `kind.isUserVisible == false` (memory, annotation,
    /// toolResult, custom) are hidden. Supply this overload to render them as custom
    /// views — e.g. a collapsible "Memory updated" banner above compression summaries.
    ///
    /// - Parameters:
    ///   - customKindRenderer: Invoked for each record whose `kind.isUserVisible == false`.
    ///     Return `AnyView(EmptyView())` to hide specific kinds selectively.
    public init<KindView: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder customKindRenderer: @escaping (ChatMessageRecord) -> KindView,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) {
        self._showModelManagement = showModelManagement
        self.customEmptyPlaceholder = nil
        self.apiConfigurationBuilder = apiConfiguration
        self.composerAccessoryBuilder = nil
        self.linkPreviewProvider = linkPreviewProvider
        self.contextMenuItemsBuilder = nil
        self.customKindRenderer = { message in AnyView(customKindRenderer(message)) }
    }

    /// Creates a ``ChatView`` without an API-configuration surface.
    ///
    /// Use this overload when the host app does not ship
    /// `ManifoldUIModelManagement` or provides API settings elsewhere.
    public init(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil
    ) where APIConfig == EmptyView {
        self.init(
            showModelManagement: showModelManagement,
            linkPreviewProvider: linkPreviewProvider,
            apiConfiguration: { EmptyView() }
        )
    }

    public init<ComposerAccessory: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder composerAccessory: @escaping () -> ComposerAccessory
    ) where APIConfig == EmptyView {
        self.init(
            showModelManagement: showModelManagement,
            linkPreviewProvider: linkPreviewProvider,
            composerAccessory: composerAccessory,
            apiConfiguration: { EmptyView() }
        )
    }

    /// Creates a ``ChatView`` with a custom empty state and no
    /// API-configuration surface.
    public init<EmptyContent: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder emptyState: () -> EmptyContent
    ) where APIConfig == EmptyView {
        self.init(
            showModelManagement: showModelManagement,
            linkPreviewProvider: linkPreviewProvider,
            emptyState: emptyState,
            apiConfiguration: { EmptyView() }
        )
    }

    public init<EmptyContent: View, ComposerAccessory: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder emptyState: () -> EmptyContent,
        @ViewBuilder composerAccessory: @escaping () -> ComposerAccessory
    ) where APIConfig == EmptyView {
        self.init(
            showModelManagement: showModelManagement,
            linkPreviewProvider: linkPreviewProvider,
            emptyState: emptyState,
            composerAccessory: composerAccessory,
            apiConfiguration: { EmptyView() }
        )
    }

    /// Creates a ``ChatView`` with host-supplied context-menu items and no
    /// API-configuration surface.
    public init<ExtraItems: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder contextMenuItems: @escaping (ChatMessageRecord) -> ExtraItems
    ) where APIConfig == EmptyView {
        self.init(
            showModelManagement: showModelManagement,
            linkPreviewProvider: linkPreviewProvider,
            contextMenuItems: contextMenuItems,
            apiConfiguration: { EmptyView() }
        )
    }

    public init<ExtraItems: View, ComposerAccessory: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder contextMenuItems: @escaping (ChatMessageRecord) -> ExtraItems,
        @ViewBuilder composerAccessory: @escaping () -> ComposerAccessory
    ) where APIConfig == EmptyView {
        self.init(
            showModelManagement: showModelManagement,
            linkPreviewProvider: linkPreviewProvider,
            contextMenuItems: contextMenuItems,
            composerAccessory: composerAccessory,
            apiConfiguration: { EmptyView() }
        )
    }

    public init<EmptyContent: View, ExtraItems: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder emptyState: () -> EmptyContent,
        @ViewBuilder contextMenuItems: @escaping (ChatMessageRecord) -> ExtraItems
    ) where APIConfig == EmptyView {
        self.init(
            showModelManagement: showModelManagement,
            linkPreviewProvider: linkPreviewProvider,
            emptyState: emptyState,
            contextMenuItems: contextMenuItems,
            apiConfiguration: { EmptyView() }
        )
    }

    public init<EmptyContent: View, ExtraItems: View, ComposerAccessory: View>(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder emptyState: () -> EmptyContent,
        @ViewBuilder contextMenuItems: @escaping (ChatMessageRecord) -> ExtraItems,
        @ViewBuilder composerAccessory: @escaping () -> ComposerAccessory
    ) where APIConfig == EmptyView {
        self.init(
            showModelManagement: showModelManagement,
            linkPreviewProvider: linkPreviewProvider,
            emptyState: emptyState,
            contextMenuItems: contextMenuItems,
            composerAccessory: composerAccessory,
            apiConfiguration: { EmptyView() }
        )
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            ChatErrorRecoveryBanner(
                viewModel: viewModel,
                showAPIConfiguration: $showAPIConfiguration,
                showModelManagement: $showModelManagement,
                apiConfiguration: apiConfigurationBuilder
            )

            if viewModel.isLoading {
                ChatLoadingContent(
                    activityPhase: viewModel.activityPhase,
                    unloadModel: { viewModel.unloadModel() }
                )
            } else if !viewModel.isModelLoaded {
                ChatNoModelLoadedContent(
                    appName: ManifoldConfiguration.shared.appName,
                    hasAvailableModels: !viewModel.availableModels.isEmpty,
                    showModelManagement: $showModelManagement
                )
            } else {
                messageList
            }

            if features.showUpgradeHint && viewModel.showUpgradeHint {
                ChatUpgradeHintBanner(showModelManagement: $showModelManagement)
            }

            Divider()
                .accessibilityHidden(true)

            ChatComposerSection(accessoryBuilder: composerAccessoryBuilder)
        }
        // Cmd+Shift+M opens Model Management from anywhere in the chat view.
        // The button must be in the view hierarchy (not toolbar) to be always active.
        .background {
            Button("") { showModelManagement = true }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .accessibilityHidden(true)
                .opacity(0)
        }
        .navigationTitle("Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // Status indicators (cloud badge, context, memory) are informational
            // and can move to the overflow menu when space is tight. The action
            // buttons (export, device info, settings, clear) carry explicit
            // `.defaultHigh` priority so they survive sidebar-hidden collapse.
            ChatToolbarContent(
                viewModel: viewModel,
                features: features,
                isDeviceInfoExpanded: $isDeviceInfoExpanded,
                isSettingsPresented: $isSettingsPresented,
                isExportPresented: $isExportPresented,
                showClearConfirmation: $showClearConfirmation,
                apiConfiguration: apiConfigurationBuilder
            )
        }
        .chatShellPresentations(
            viewModel: viewModel,
            showClearConfirmation: $showClearConfirmation,
            isSettingsPresented: $isSettingsPresented,
            isExportPresented: $isExportPresented,
            apiConfiguration: apiConfigurationBuilder
        )
        // API configuration: on compact size class (iPhone) or macOS, use a full sheet
        // because there is no stable toolbar anchor. On regular size class (iPad) the
        // presentation is anchored to the recovery button's popover.
        .chatAPIConfigurationPresentation(
            isPresented: $showAPIConfiguration,
            apiConfiguration: apiConfigurationBuilder
        )
    }

    // MARK: - Message List

    private var messageList: some View {
        ChatHistoryView(
            customEmptyPlaceholder: customEmptyPlaceholder,
            linkPreviewProvider: linkPreviewProvider,
            contextMenuItemsBuilder: contextMenuItemsBuilder,
            customKindRenderer: customKindRenderer
        )
    }

    // MARK: - Helpers

    static func canConsumeScrollToMessageRequest(
        _ request: ChatScrollToMessageRequest,
        in messages: [ChatMessageRecord]
    ) -> Bool {
        ChatHistoryScrollBehavior.canConsumeScrollToMessageRequest(request, in: messages)
    }
}

// MARK: - Preview

#Preview("Chat View") {
    NavigationStack {
        ChatView(
            showModelManagement: .constant(false),
            apiConfiguration: { EmptyView() }
        )
    }
    .environment(ChatViewModel())
}
