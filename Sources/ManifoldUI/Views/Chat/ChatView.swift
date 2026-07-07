import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// The main chat view, displayed in the detail area of the app's navigation structure.
///
/// Shows a scrolling message history with auto-scroll, an input bar at the
/// bottom, and toolbar actions for device info, settings, and clearing the chat.
///
/// ## Customization
///
/// `ChatView` has a single initializer. Every optional customization seam is a
/// modifier applied to the constructed view, not an initializer overload:
///
/// - ``chatEmptyState(_:)`` — replaces the placeholder shown when the active
///   session has no messages.
/// - ``chatComposerAccessory(_:)`` — renders a host-supplied accessory (photo
///   attachment, voice capture, …) above the stock composer.
/// - ``chatContextMenuItems(_:)`` — appends extra per-message context-menu
///   items after the built-in pin/copy/edit/regenerate/branch/delete actions.
/// - ``chatCustomKindRenderer(_:)`` — renders non-user-visible message kinds
///   (memory, annotation, tool-result, custom) that are hidden by default.
/// - ``chatAPIConfiguration(_:)`` — supplies the host's API-key recovery view,
///   presented as a sheet/popover. Typically `{ APIConfigurationView() }` from
///   `ManifoldUIModelManagement`. Defaults to an empty sheet when omitted —
///   the closure-injection pattern keeps `ManifoldUI` free of any back-edge to
///   the model-management module.
///
/// **Composition is LAST-WINS.** Applying the same modifier more than once
/// replaces the previous closure entirely — there is no merging of two
/// `chatEmptyState { ... }` calls, for example. Each modifier's doc comment
/// restates this.
///
/// All builder closures are stored and invoked at render/presentation time,
/// not at the point the modifier is applied — so `@Environment` / `@Bindable`
/// lookups inside the supplied view, and any state mutated after `ChatView`
/// was constructed, resolve against the live view tree.
public struct ChatView: View {

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
    #if DEBUG
    @State private var showArchitectView: Bool = false
    #endif

    private let linkPreviewProvider: LinkPreviewProvider?

    /// Optional replacement for the built-in "Send a message to start chatting."
    /// placeholder shown when the session has no messages. Set via
    /// ``chatEmptyState(_:)``.
    ///
    /// Held as a closure and evaluated at render time (not eagerly at
    /// modifier-application time) so it reflects state mutated after
    /// `ChatView` was constructed — e.g. an `@Observable` model whose
    /// properties change after the view is built. Previously this was built
    /// eagerly into a stored `AnyView` at init, which froze whatever state
    /// existed at construction time; that was a latent staleness bug.
    private var emptyStateBuilder: (() -> AnyView)?

    /// Builder for the API configuration view, set via ``chatAPIConfiguration(_:)``.
    /// Defaults to an empty sheet so hosts that don't ship
    /// `ManifoldUIModelManagement` need not call the modifier at all.
    private var apiConfigurationBuilder: () -> AnyView = { AnyView(EmptyView()) }

    /// Optional host-supplied accessory rendered above the stock composer,
    /// set via ``chatComposerAccessory(_:)``. This is the integration seam
    /// for add-ons such as voice capture without forcing `ManifoldUI` to
    /// depend on optional sibling modules.
    private var composerAccessoryBuilder: (() -> AnyView)?

    /// Builder for extra per-message context-menu items rendered after the
    /// built-in actions (pin, copy, edit, regenerate, branch, delete), set via
    /// ``chatContextMenuItems(_:)``. `nil` means only the built-in items appear.
    /// The closure is invoked per message so hosts can vary items by role or
    /// content.
    private var contextMenuItemsBuilder: ((ChatMessage) -> AnyView)?

    /// Optional renderer for non-user-visible kind records, set via
    /// ``chatCustomKindRenderer(_:)``. By default these are hidden. Hosts
    /// supply this to render memory bubbles, annotation labels, or other
    /// internal records.
    private var customKindRenderer: ((ChatMessage) -> AnyView)?

    public init(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil
    ) {
        self._showModelManagement = showModelManagement
        self.linkPreviewProvider = linkPreviewProvider
    }

    // MARK: - Modifier slots

    /// Replaces the built-in "Send a message to start chatting." placeholder
    /// shown when the active session has no messages.
    ///
    /// The closure is evaluated at render time, so it reflects state mutated
    /// after `ChatView` was constructed.
    ///
    /// **LAST-WINS:** calling this modifier more than once replaces the
    /// previous empty-state builder entirely; there is no merging.
    public func chatEmptyState<Content: View>(
        @ViewBuilder _ builder: @escaping () -> Content
    ) -> ChatView {
        var copy = self
        copy.emptyStateBuilder = { AnyView(builder()) }
        return copy
    }

    /// Supplies the host's API-key recovery / configuration view, presented
    /// as a sheet or popover from the error-recovery banner, the settings
    /// sheet, and the toolbar's API-key check flow.
    ///
    /// Typically `{ APIConfigurationView() }` from `ManifoldUIModelManagement`.
    /// The closure is invoked at sheet/popover presentation time, not when
    /// this modifier is applied, so `@Environment` / `@Bindable` lookups
    /// inside the supplied view resolve against the live view tree.
    ///
    /// **LAST-WINS:** calling this modifier more than once replaces the
    /// previous builder entirely; there is no merging.
    public func chatAPIConfiguration<Content: View>(
        @ViewBuilder _ builder: @escaping () -> Content
    ) -> ChatView {
        var copy = self
        copy.apiConfigurationBuilder = { AnyView(builder()) }
        return copy
    }

    /// Renders a host-supplied accessory above the stock composer — e.g. a
    /// photo-attachment button or a voice-capture control.
    ///
    /// **LAST-WINS:** calling this modifier more than once replaces the
    /// previous accessory builder entirely; there is no merging.
    public func chatComposerAccessory<Content: View>(
        @ViewBuilder _ builder: @escaping () -> Content
    ) -> ChatView {
        var copy = self
        copy.composerAccessoryBuilder = { AnyView(builder()) }
        return copy
    }

    /// Appends host-supplied items to each message's context menu, after the
    /// built-in pin/copy/edit/regenerate/branch/delete actions.
    ///
    /// The closure is invoked per ``ChatMessage`` so hosts can vary items by
    /// role or content.
    ///
    /// **LAST-WINS:** calling this modifier more than once replaces the
    /// previous builder entirely; there is no merging.
    public func chatContextMenuItems<Content: View>(
        @ViewBuilder _ builder: @escaping (ChatMessage) -> Content
    ) -> ChatView {
        var copy = self
        copy.contextMenuItemsBuilder = { message in AnyView(builder(message)) }
        return copy
    }

    /// Renders non-user-visible kind records — those with
    /// `kind.isUserVisible == false` (memory, annotation, toolResult, custom)
    /// — which are hidden by default. Return `AnyView(EmptyView())` from the
    /// closure to hide specific kinds selectively.
    ///
    /// **LAST-WINS:** calling this modifier more than once replaces the
    /// previous renderer entirely; there is no merging.
    public func chatCustomKindRenderer<Content: View>(
        @ViewBuilder _ builder: @escaping (ChatMessage) -> Content
    ) -> ChatView {
        var copy = self
        copy.customKindRenderer = { message in AnyView(builder(message)) }
        return copy
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
            #if DEBUG
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showArchitectView = true
                } label: {
                    Label("Architect", systemImage: "magnifyingglass.circle")
                }
                .accessibilityLabel("Open Architect developer inspector")
                .accessibilityIdentifier("architect-toolbar-button")
            }
            #endif
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
        #if DEBUG
        .sheet(isPresented: $showArchitectView) {
            ArchitectView(
                runtime: viewModel.runtime,
                capabilities: viewModel.backendCapabilities,
                imageRuntime: viewModel.imageRuntime,
                videoRuntime: viewModel.videoRuntime
            )
        }
        #endif
    }

    // MARK: - Message List

    private var messageList: some View {
        ChatHistoryView(
            emptyStateBuilder: emptyStateBuilder,
            linkPreviewProvider: linkPreviewProvider,
            contextMenuItemsBuilder: contextMenuItemsBuilder,
            customKindRenderer: customKindRenderer
        )
    }

    // MARK: - Helpers

    static func canConsumeScrollToMessageRequest(
        _ request: ChatScrollToMessageRequest,
        in messages: [ChatMessage]
    ) -> Bool {
        ChatHistoryScrollBehavior.canConsumeScrollToMessageRequest(request, in: messages)
    }
}

// MARK: - Preview

#Preview("Chat View") {
    NavigationStack {
        ChatView(showModelManagement: .constant(false))
    }
    .environment(ChatViewModel())
}
