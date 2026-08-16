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
///
/// ## Customization
///
/// `ChatView` has two initializers — the designated one (`apiConfiguration:`
/// required) and a convenience for hosts that don't ship an API-configuration
/// surface at all (`APIConfig == EmptyView`). Every *other* optional
/// customization seam that used to be a combinatorial initializer overload is
/// now a modifier applied to the constructed view instead:
///
/// - ``chatEmptyState(_:)`` — replaces the placeholder shown when the active
///   session has no messages.
/// - ``chatComposerAccessory(_:)`` — renders a host-supplied accessory (photo
///   attachment, voice capture, …) above the stock composer.
/// - ``chatContextMenuItems(_:)`` — appends extra per-message context-menu
///   items after the built-in pin/copy/edit/regenerate/branch/delete actions.
/// - ``chatCustomKindRenderer(_:)`` — renders non-user-visible message kinds
///   (memory, annotation, tool-result, custom) that are hidden by default.
/// - ``chatAPIConfiguration(_:)`` — switches the API configuration view after
///   construction (an alternative to passing `apiConfiguration:` at init).
///
/// **Composition is LAST-WINS.** Applying the same modifier more than once
/// replaces the previous closure entirely — there is no merging of two
/// `chatEmptyState { ... }` calls, for example. Each modifier's doc comment
/// restates this.
///
/// All builder closures (including `apiConfiguration`) are invoked at
/// render/presentation time, not at the point the initializer or modifier is
/// applied — so `@Environment` / `@Bindable` lookups inside the supplied
/// view, and any state mutated after `ChatView` was constructed, resolve
/// against the live view tree.
public struct ChatView<APIConfig: View>: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.endpointStore) private var endpointStore
    @Environment(\.manifoldTheme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var features: ManifoldConfiguration.Features { ManifoldConfiguration.shared.features }

    /// Controls the model management sheet. Passed in from the host app so that the
    /// "Browse Models" button in the empty state can open it directly.
    @Binding public var showModelManagement: Bool

    @State private var isDeviceInfoExpanded: Bool = false
    @State private var isSettingsPresented: Bool = false
    @State private var isExportPresented: Bool = false
    @State private var showClearConfirmation: Bool = false
    @State private var showAPIConfiguration: Bool = false
    @Binding private var apiConfigurationPresentationTestingBinding: Bool
    private var usesAPIConfigurationPresentationTestingBinding = false
    @State private var showModelSwitcher: Bool = false
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

    /// Builder for the API configuration view. Held as a closure (rather than the
    /// pre-built view) so that any `@Environment` / `@Bindable` lookups inside
    /// `APIConfigurationView` resolve at sheet/popover presentation time, not at
    /// `ChatView` init.
    private let apiConfigurationBuilder: () -> APIConfig

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

    /// Optional host-supplied quick model switcher content, set via
    /// ``chatModelSwitcher(_:)``. `nil` (the default) renders no model chip
    /// in the toolbar at all — the seam is opt-in because building the row
    /// list (`ModelSwitcher.rows(...)`) needs `ManifoldUIModelManagement`
    /// types this module must not import (dependency direction: mmgmt
    /// depends on UI, never the reverse).
    private var modelSwitcherBuilder: (() -> AnyView)?

    public init(
        showModelManagement: Binding<Bool>,
        linkPreviewProvider: LinkPreviewProvider? = nil,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) {
        self._showModelManagement = showModelManagement
        self._apiConfigurationPresentationTestingBinding = .constant(false)
        self.linkPreviewProvider = linkPreviewProvider
        self.apiConfigurationBuilder = apiConfiguration
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
    ) -> ChatView<APIConfig> {
        var copy = self
        copy.emptyStateBuilder = { AnyView(builder()) }
        return copy
    }

    /// Switches the API-key recovery / configuration view presented as a
    /// sheet or popover from the error-recovery banner, the settings sheet,
    /// and the toolbar's API-key check flow — an alternative to passing
    /// `apiConfiguration:` to the initializer.
    ///
    /// Typically `{ APIConfigurationView() }` from `ManifoldUIModelManagement`.
    /// The closure is invoked at sheet/popover presentation time, not when
    /// this modifier is applied, so `@Environment` / `@Bindable` lookups
    /// inside the supplied view resolve against the live view tree.
    ///
    /// **LAST-WINS:** calling this modifier more than once (or after
    /// supplying `apiConfiguration:` at init) replaces the previous builder
    /// entirely; there is no merging.
    public func chatAPIConfiguration<Content: View>(
        @ViewBuilder _ builder: @escaping () -> Content
    ) -> ChatView<Content> {
        var copy = ChatView<Content>(
            showModelManagement: $showModelManagement,
            linkPreviewProvider: linkPreviewProvider,
            apiConfiguration: builder
        )
        copy.emptyStateBuilder = emptyStateBuilder
        copy.composerAccessoryBuilder = composerAccessoryBuilder
        copy.contextMenuItemsBuilder = contextMenuItemsBuilder
        copy.customKindRenderer = customKindRenderer
        copy.modelSwitcherBuilder = modelSwitcherBuilder
        return copy
    }

    /// Test-only state driver for the concrete sheet/popover owned by this
    /// view. Kept internal so consumers do not gain a second configuration
    /// presentation API; production enters the state through its recovery,
    /// first-run, and settings actions.
    func presentingAPIConfigurationForTesting(
        _ isPresented: Binding<Bool>
    ) -> ChatView<APIConfig> {
        var copy = self
        copy._apiConfigurationPresentationTestingBinding = isPresented
        copy.usesAPIConfigurationPresentationTestingBinding = true
        return copy
    }

    /// Renders a host-supplied accessory above the stock composer — e.g. a
    /// photo-attachment button or a voice-capture control.
    ///
    /// **LAST-WINS:** calling this modifier more than once replaces the
    /// previous accessory builder entirely; there is no merging.
    public func chatComposerAccessory<Content: View>(
        @ViewBuilder _ builder: @escaping () -> Content
    ) -> ChatView<APIConfig> {
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
    ) -> ChatView<APIConfig> {
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
    ) -> ChatView<APIConfig> {
        var copy = self
        copy.customKindRenderer = { message in AnyView(builder(message)) }
        return copy
    }

    /// Installs a quick model switcher, presented from a toolbar chip —
    /// popover-anchored on macOS (spec §2: "Glass popover anchored to the
    /// toolbar chip"), a sheet with `.presentationDetents` on iOS (spec §2:
    /// "Glass sheet + detents"). `ChatView` owns only the chrome (chip,
    /// presentation style); the content itself is host-supplied because
    /// building the unified row list needs `ManifoldUIModelManagement` types
    /// (`ModelSwitcher.rows(...)`, `EndpointStore`) this module cannot import.
    ///
    /// Typically:
    /// ```swift
    /// ChatView(showModelManagement: $show)
    ///     .chatModelSwitcher {
    ///         ModelSwitcherView(
    ///             rows: ModelSwitcher.rows(
    ///                 models: vm.availableModels,
    ///                 endpoints: endpoints,
    ///                 selectedModelID: vm.selectedModel?.id,
    ///                 selectedEndpointID: vm.selectedEndpoint?.id,
    ///                 physicalMemoryBytes: vm.physicalMemoryBytes,
    ///                 compatibility: capabilityService.compatibility(for:)
    ///             ),
    ///             onSelect: { entry in /* dispatch selection */ },
    ///             onFixEndpoint: { endpoint in /* open the endpoint editor */ }
    ///         )
    ///     }
    /// ```
    ///
    /// `nil` (never calling this modifier) renders no model chip at all — the
    /// seam is opt-in, matching `chatComposerAccessory(_:)`'s shape.
    ///
    /// **LAST-WINS:** calling this modifier more than once replaces the
    /// previous builder entirely; there is no merging.
    ///
    /// **Ordering:** like the other chat seams, this method chains on the
    /// concrete `ChatView` type — apply it together with
    /// `chatEmptyState`/`chatComposerAccessory`/`chatAPIConfiguration`,
    /// *before* any generic `View` modifier (`.chatTheme(_:)`,
    /// `.chatMessageRenderer(_:)`, `.toolbar { }`, …) erases the chain to
    /// `some View`, after which this method no longer resolves.
    public func chatModelSwitcher<Content: View>(
        @ViewBuilder _ builder: @escaping () -> Content
    ) -> ChatView<APIConfig> {
        var copy = self
        copy.modelSwitcherBuilder = { AnyView(builder()) }
        return copy
    }

    // MARK: - Body

    public var body: some View {
        let apiConfiguration = {
            chatAPIConfigurationContent(
                apiConfigurationBuilder,
                endpointStore: endpointStore
            )
        }

        chromeBody(apiConfiguration: apiConfiguration)
        .onAppear {
            if usesAPIConfigurationPresentationTestingBinding {
                showAPIConfiguration = apiConfigurationPresentationTestingBinding
            }
        }
        .onChange(of: apiConfigurationPresentationTestingBinding) { _, isPresented in
            if usesAPIConfigurationPresentationTestingBinding {
                showAPIConfiguration = isPresented
            }
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
        // Compact width mounts the model chip in content chrome instead of
        // the toolbar (see `showsModelChipInToolbar`): iOS 26's compact bar
        // collapses items into the "More" overflow via undocumented
        // heuristics — `.principal` gets dropped outright, bar-button
        // placements collapse into overflow, and an overflow-collapsed row
        // of this chip renders but does not activate (#2307). A
        // `safeAreaInset` band is deterministic: always visible, always
        // tappable, owned by us.
        .safeAreaInset(edge: .top, spacing: 0) {
            if modelSwitcherBuilder != nil && !Self.showsModelChipInToolbar(horizontalSizeClass: horizontalSizeClass) {
                modelChipInsetBar
            }
        }
        .toolbar {
            if modelSwitcherBuilder != nil && Self.showsModelChipInToolbar(horizontalSizeClass: horizontalSizeClass) {
                ToolbarItem(placement: .principal) {
                    modelChipButton
                }
            }
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
                apiConfiguration: apiConfiguration
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
            apiConfiguration: apiConfiguration
        )
        // API configuration: on compact size class (iPhone) or macOS, use a full sheet
        // because there is no stable toolbar anchor. On regular size class (iPad) the
        // presentation is anchored to the recovery button's popover.
        .chatAPIConfigurationPresentation(
            isPresented: $showAPIConfiguration,
            apiConfiguration: apiConfiguration
        )
        // Model-switcher presentation lives on the stable content hierarchy,
        // NOT on the toolbar chip button — a chip collapsed into the "More"
        // overflow menu cannot anchor a presentation (its hosted view dies
        // with the menu's dismissal, silently dropping the sheet — #2307).
        #if os(iOS)
        .sheet(isPresented: $showModelSwitcher) {
            modelSwitcherContent
                .presentationDetents([.medium, .large])
        }
        #else
        .popover(isPresented: $showModelSwitcher) {
            modelSwitcherContent
                .frame(minWidth: 320, minHeight: 360)
        }
        #endif
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

    // MARK: - Chrome (Unit 2 §L1)

    /// The banner/loading/message-list/upgrade-hint stack shared by both
    /// chrome shapes below — everything above the composer seam.
    private func mainContent(apiConfiguration: @escaping () -> AnyView) -> some View {
        VStack(spacing: 0) {
            ChatErrorRecoveryBanner(
                viewModel: viewModel,
                showAPIConfiguration: $showAPIConfiguration,
                showModelManagement: $showModelManagement,
                apiConfiguration: apiConfiguration
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
                    isFirstRun: viewModel.isFirstRun,
                    showModelManagement: $showModelManagement,
                    showAPIConfiguration: $showAPIConfiguration
                )
            } else {
                messageList
            }

            if features.showUpgradeHint && viewModel.showUpgradeHint {
                ChatUpgradeHintBanner(showModelManagement: $showModelManagement)
            }
        }
    }

    /// Picks the composer-seam treatment: iOS gets the glass edge-to-edge
    /// shape at every supported OS version (spec §9 — "iOS fallback:
    /// identical geometry in `.regularMaterial`", i.e. the *geometry* isn't
    /// gated to 26+, only which material renders it, and
    /// ``View/manifoldGlass(_:in:)`` already resolves that per-OS). macOS
    /// keeps the divider-seam shape unchanged here — the docked,
    /// width-constrained glass composer bar is Unit 2 §L3's job
    /// (`ChatComposerSection` itself lives outside this tranche's owned
    /// files), and macOS chrome must stay system-toolbar-owned regardless.
    @ViewBuilder
    private func chromeBody(apiConfiguration: @escaping () -> AnyView) -> some View {
        #if os(iOS)
        edgeToEdgeGlassChromeBody(apiConfiguration: apiConfiguration)
        #else
        classicChromeBody(apiConfiguration: apiConfiguration)
        #endif
    }

    /// Pre-refresh shape: an opaque `Divider()` seam between the transcript
    /// and the composer, stacked in a plain `VStack`. Still used on macOS.
    private func classicChromeBody(apiConfiguration: @escaping () -> AnyView) -> some View {
        VStack(spacing: 0) {
            mainContent(apiConfiguration: apiConfiguration)
            Divider()
                .accessibilityHidden(true)
            ChatComposerSection(accessoryBuilder: composerAccessoryBuilder)
        }
    }

    /// iOS shape: the composer rides in the scroll view's bottom safe-area
    /// inset instead of a stacked sibling, so the transcript scrolls
    /// edge-to-edge beneath it — replacing the `Divider()` seam
    /// (`docs/UI-REFRESH-2026.md` §1 "Content scrolls under glass",
    /// §2 composer row). `safeAreaInset` still reserves layout space for the
    /// composer (messages never render fully hidden behind it at rest); the
    /// translucent ``manifoldGlass(_:in:)`` background is what lets content
    /// visibly slide beneath it while scrolling, same contract as a
    /// `List`/`ScrollView` floating toolbar.
    private func edgeToEdgeGlassChromeBody(apiConfiguration: @escaping () -> AnyView) -> some View {
        mainContent(apiConfiguration: apiConfiguration)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatComposerSection(accessoryBuilder: composerAccessoryBuilder)
                    .manifoldGlass(theme, in: Rectangle())
            }
    }

    // MARK: - Model switcher chip (Unit 2 §L5)

    /// Whether the model chip renders as a `.principal` toolbar item
    /// (regular width / macOS) or in the content-chrome `safeAreaInset` band
    /// (compact width). Compact toolbars collapse items via undocumented
    /// heuristics that either drop the chip outright (`.principal`) or park
    /// it in an overflow-menu row that renders but does not activate —
    /// verified on iOS 26 across `.principal`/`.topBarTrailing`/`.automatic`
    /// (#2307). macOS always returns `true` (no compact size class there).
    static func showsModelChipInToolbar(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        #if os(iOS)
        horizontalSizeClass != .compact
        #else
        true
        #endif
    }

    /// The compact-width content-chrome band hosting the model chip —
    /// deterministic replacement for the toolbar placement (#2307). Sits as
    /// a `safeAreaInset` under the navigation bar, styled on theme tokens.
    private var modelChipInsetBar: some View {
        HStack {
            modelChipButton
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// The toolbar chip that opens the host-supplied model switcher content
    /// (``chatModelSwitcher(_:)``). macOS presents it as a popover anchored
    /// to this chip (spec §2); iOS presents it as a sheet with
    /// `.presentationDetents` (spec §2) — `presentationDetents` is an
    /// iOS-only API, so it is guarded behind `#if os(iOS)`.
    private var modelChipButton: some View {
        Button {
            showModelSwitcher = true
        } label: {
            Label(modelChipTitle, systemImage: "cpu")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("Switch model")
        .accessibilityIdentifier("chat-model-switcher-chip")
        // The presentation is deliberately NOT attached here: when this
        // toolbar item collapses into the "More" overflow menu (compact
        // width, crowded bar — the #2307 fallback path), the button's
        // hosted view lives inside the transient menu, and a sheet anchored
        // to it is torn down with the menu before it can present. The
        // sheet/popover hangs off the stable content hierarchy in `body`
        // instead (see the `showModelSwitcher` presentation there).
    }

    @ViewBuilder
    private var modelSwitcherContent: some View {
        if let modelSwitcherBuilder {
            modelSwitcherBuilder()
        } else {
            EmptyView()
        }
    }

    /// The chip's label: the active local model's name, else the active
    /// cloud endpoint's name, else the backend-reported model identifier
    /// (e.g. a Foundation Models session with no `ModelInfo`/endpoint
    /// selection), else a neutral fallback so the chip is never blank.
    private var modelChipTitle: String {
        viewModel.selectedModel?.name
            ?? viewModel.selectedEndpoint?.name
            ?? viewModel.activeModelName
            ?? "Model"
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
