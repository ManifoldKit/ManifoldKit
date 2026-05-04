import SwiftUI
import BaseChatRuntime
import BaseChatInference

/// The main chat view, displayed in the detail area of the app's navigation structure.
///
/// Shows a scrolling message history with auto-scroll, an input bar at the
/// bottom, and toolbar actions for device info, settings, and clearing the chat.
///
/// `APIConfig` is the type of the host-supplied API configuration view, which
/// `ChatView` presents as a sheet/popover when the user triggers the API key
/// recovery flow. Callers typically pass `{ APIConfigurationView() }` from
/// `BaseChatUIModelManagement`. The closure-injection keeps `BaseChatUI` free
/// of any back-edge to the model-management module.
public struct ChatView<APIConfig: View>: View {

    @Environment(ChatViewModel.self) private var viewModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var features: BaseChatConfiguration.Features { BaseChatConfiguration.shared.features }

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
    /// forcing `BaseChatUI` to depend on optional sibling modules.
    private let composerAccessoryBuilder: (() -> AnyView)?

    /// Optional opt-in metadata provider for URL preview cards in messages.
    ///
    /// The default is `nil`: `BaseChatUI` performs no network fetching and
    /// renders no link previews unless a host supplies this closure.
    private let linkPreviewProvider: LinkPreviewProvider?

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
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            errorBanner

            if viewModel.isLoading {
                loadingView
            } else if !viewModel.isModelLoaded {
                noModelLoadedView
            } else {
                messageList
            }

            if features.showUpgradeHint && viewModel.showUpgradeHint {
                upgradeHintBanner
            }

            Divider()
                .accessibilityHidden(true)

            composerSection
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
            ToolbarItemGroup(placement: .automatic) {
                if let backend = viewModel.activeBackendName,
                   ["OpenAI", "Claude", "Ollama", "LM Studio"].contains(backend) {
                    Label("Cloud", systemImage: "cloud.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Using cloud backend: \(backend)")
                }
                if features.showContextIndicator {
                    ContextIndicatorView(
                        usedTokens: viewModel.contextUsedTokens,
                        maxTokens: viewModel.contextMaxTokens
                    )
                }
                if features.showMemoryIndicator {
                    MemoryIndicatorView(
                        pressureLevel: viewModel.memoryPressureLevel,
                        physicalMemoryBytes: viewModel.physicalMemoryBytes,
                        appMemoryBytes: viewModel.appMemoryUsageBytes
                    )
                }
                if features.showChatExport {
                    exportButton
                }
                deviceInfoButton
                if features.showGenerationSettings {
                    settingsButton
                }
                clearChatButton
            }
        }
        .alert("Clear Chat", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await viewModel.clearChat() }
            }
        } message: {
            Text("This will delete all messages in the current chat. This cannot be undone.")
        }
        // On macOS, settings and export are presented as sheets from here because
        // the toolbar buttons use `.popover` only on iOS (see button definitions below).
        #if !os(iOS)
        .sheet(isPresented: $isSettingsPresented) {
            GenerationSettingsView(apiConfiguration: apiConfigurationBuilder)
        }
        .sheet(isPresented: $isExportPresented) {
            ChatExportSheet()
        }
        #endif
        // API configuration: on compact size class (iPhone) or macOS, use a full sheet
        // because there is no stable toolbar anchor. On regular size class (iPad) the
        // presentation is anchored to the recovery button via `.popover` — see
        // `recoveryButton(for:)` below which attaches the popover directly to the button
        // so the sheet modifier here is skipped on that path.
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { showAPIConfiguration && horizontalSizeClass == .compact },
            set: { if !$0 { showAPIConfiguration = false } }
        )) {
            apiConfigurationBuilder()
                .presentationDragIndicator(.visible)
        }
        #else
        .sheet(isPresented: $showAPIConfiguration) {
            apiConfigurationBuilder()
        }
        #endif
    }

    @ViewBuilder
    private var composerSection: some View {
        VStack(spacing: 0) {
            if let composerAccessoryBuilder {
                composerAccessoryBuilder()
            }
            ChatInputBar()
        }
    }

    // MARK: - Error Banner

    @ViewBuilder
    private var errorBanner: some View {
        if let error = viewModel.activeError {
            ErrorBannerView(
                error: error,
                onDismiss: { viewModel.activeError = nil },
                recoveryAction: {
                    recoveryButton(for: error.recovery)
                }
            )
        }
    }

    @ViewBuilder
    private func recoveryButton(for recovery: ChatError.Recovery?) -> some View {
        switch recovery {
        case .retry:
            Button("Retry") {
                viewModel.activeError = nil
                Task {
                    await viewModel.regenerateLastResponse()
                }
            }
            .buttonStyle(.borderless)
            .font(.callout.bold())
        case .configureAPIKey:
            Button("Check API Key") {
                #if os(iOS)
                // On regular size class (iPad) the popover is anchored to this button,
                // so we must NOT clear activeError here — doing so removes the error
                // banner (and this button) from the view tree before SwiftUI can capture
                // the anchor, causing the popover to present without an anchor or not at
                // all. Instead, we clear activeError in the popover's dismissal handler.
                // On compact (iPhone) the sheet is attached to the root view rather than
                // this button, so the anchor disappearing is harmless there.
                if horizontalSizeClass == .regular {
                    showAPIConfiguration = true
                } else {
                    viewModel.activeError = nil
                    showAPIConfiguration = true
                }
                #else
                viewModel.activeError = nil
                showAPIConfiguration = true
                #endif
            }
            .buttonStyle(.borderless)
            .font(.callout.bold())
            #if os(iOS)
            // On regular size class (iPad), anchor the API config as a popover on the
            // recovery button so the split view stays visible. On compact (iPhone) the
            // view-level `.sheet` above handles presentation instead.
            .popover(isPresented: Binding(
                get: { showAPIConfiguration && horizontalSizeClass == .regular },
                set: {
                    if !$0 {
                        showAPIConfiguration = false
                        // Clear the error now that the popover is gone — this removes the
                        // banner and keeps the screen clean after the user is done
                        // configuring their API key.
                        viewModel.activeError = nil
                    }
                }
            )) {
                apiConfigurationBuilder()
                    .frame(minWidth: 360, minHeight: 440)
            }
            #endif
        case .selectModel:
            Button("Select Model") {
                viewModel.activeError = nil
                showModelManagement = true
            }
            .buttonStyle(.borderless)
            .font(.callout.bold())
            .accessibilityIdentifier("chat-model-management-button")
        case .dismissOnly, .none:
            EmptyView()
        }
    }

    // MARK: - Upgrade Hint Banner

    private var upgradeHintBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            Text("Want longer responses? Download a model for extended context.")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                showModelManagement = true
            } label: {
                Text("Browse")
                    .font(.callout.bold())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
            .accessibilityLabel("Browse models for extended context")
            .accessibilityIdentifier("chat-model-management-button")
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.top, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Loading

    private var loadingView: some View {
        Group {
            if case .modelLoading(let progress) = viewModel.activityPhase {
                ModelLoadingIndicatorView(progress: progress) {
                    viewModel.unloadModel()
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - No Model Loaded

    @ViewBuilder
    private var noModelLoadedView: some View {
        if viewModel.availableModels.isEmpty {
            // No models at all — welcome screen with browse CTA
            VStack(spacing: 20) {
                Image(systemName: "book.and.wrench")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text("Welcome to \(BaseChatConfiguration.shared.appName)")
                        .font(.title2.bold())

                    Text("Download a model to get started, or connect a cloud API in settings.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                Button {
                    showModelManagement = true
                } label: {
                    Label("Browse Models", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("Browse and download models")
                .accessibilityIdentifier("chat-model-management-button")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            // Models exist but none is selected — on iPhone there is no visible sidebar,
            // so provide a button to open model management directly.
            ContentUnavailableView {
                Label("No Model Selected", systemImage: "cpu")
            } description: {
                Text("Select a model from the sidebar to start chatting.")
            } actions: {
                Button("Select Model") {
                    showModelManagement = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("chat-model-management-button")
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    // Trigger for loading older messages when the user scrolls to the top.
                    if viewModel.hasOlderMessages {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .onAppear {
                                loadOlderAndRestore(proxy: proxy)
                            }
                    }

                    if viewModel.messages.isEmpty && !viewModel.isGenerating {
                        emptyPlaceholder
                    }

                    ForEach(viewModel.messages) { message in
                        MessageBubbleView(
                            message: message,
                            isStreaming: isMessageStreaming(message),
                            isPinned: viewModel.isMessagePinned(id: message.id),
                            linkPreviewProvider: linkPreviewProvider
                        )
                        .messageActionMenu(message: message, viewModel: viewModel)
                        .id(message.id)
                    }

                    // Invisible anchor for auto-scrolling.
                    Color.clear
                        .frame(height: 1)
                        .id("chatBottom")
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: viewModel.messages.count) {
                // Only auto-scroll to bottom for new messages appended at the end,
                // not when older messages are prepended at the top.
                if !viewModel.isLoadingOlderMessages {
                    scrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: viewModel.messages.last?.content) {
                scrollToBottom(proxy: proxy)
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyPlaceholder: some View {
        if let customEmptyPlaceholder {
            customEmptyPlaceholder
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            Text("Send a message to start chatting.")
                .foregroundStyle(.tertiary)
                .font(.body)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    // MARK: - Toolbar Items

    private var exportButton: some View {
        Button {
            isExportPresented = true
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(viewModel.messages.isEmpty)
        .accessibilityLabel("Export chat")
        #if os(iOS)
        // On regular size class (iPad), anchor the export panel as a popover so
        // the split-view context stays visible. On compact (iPhone), the popover
        // automatically adapts to a sheet presentation.
        .popover(isPresented: $isExportPresented) {
            ChatExportSheet()
                .frame(minWidth: 320, minHeight: 300)
        }
        #endif
    }

    private var deviceInfoButton: some View {
        Button {
            isDeviceInfoExpanded.toggle()
        } label: {
            Label("Device Info", systemImage: "info.circle")
        }
        .popover(isPresented: $isDeviceInfoExpanded) {
            deviceInfoPopover
        }
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Label("Settings", systemImage: "gear")
        }
        .accessibilityLabel("Generation settings")
        .accessibilityIdentifier("chat-settings-button")
        #if os(iOS)
        // Cmd+, is the iPadOS convention for settings with a hardware keyboard.
        // Omitted on macOS to avoid conflicting with any host app's Settings scene
        // (which also claims Cmd+,).
        .keyboardShortcut(",", modifiers: .command)
        .popover(isPresented: $isSettingsPresented) {
            GenerationSettingsView(apiConfiguration: apiConfigurationBuilder)
                .frame(minWidth: 320, minHeight: 400)
        }
        #endif
    }

    private var clearChatButton: some View {
        Button {
            showClearConfirmation = true
        } label: {
            Label("Clear Chat", systemImage: "trash")
        }
        .disabled(viewModel.messages.isEmpty)
        .accessibilityLabel("Clear chat")
        // Cmd+Shift+K mirrors the "Clear" shortcut convention used in Xcode and Terminal.
        .keyboardShortcut("k", modifiers: [.command, .shift])
    }

    // MARK: - Device Info Popover

    private var deviceInfoPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device Info")
                .font(.headline)

            LabeledContent("Device") {
                Text(viewModel.deviceDescription)
            }

            LabeledContent("Recommended Size") {
                Text(viewModel.recommendedSize.description)
            }

            LabeledContent("Model Loaded") {
                Text(viewModel.isModelLoaded ? "Yes" : "No")
                    .foregroundStyle(viewModel.isModelLoaded ? .green : .secondary)
            }
            .accessibilityValue(viewModel.isModelLoaded ? "Yes" : "No")

            if let modelName = viewModel.activeModelName {
                LabeledContent("Model") {
                    Text(modelName)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }

            if let backend = viewModel.activeBackendName {
                LabeledContent("Backend") {
                    Text(backend)
                }
            }
        }
        .padding()
        .frame(minWidth: 280)
    }

    // MARK: - Helpers

    private func isMessageStreaming(_ message: ChatMessageRecord) -> Bool {
        viewModel.isGenerating
        && message.role == .assistant
        && message.id == viewModel.messages.last?.id
    }

    /// Loads the next page of older messages and scrolls back to the anchor
    /// so the viewport doesn't jump when content is prepended above.
    private func loadOlderAndRestore(proxy: ScrollViewProxy) {
        Task { @MainActor in
            guard let anchorID = await viewModel.loadOlderMessages() else { return }
            // Scroll back to the message that was at the top before prepend,
            // keeping it at the top of the viewport to prevent visible jump.
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("chatBottom", anchor: .bottom)
        }
    }
}

// MARK: - Error Banner View

/// Standalone chat error banner.
///
/// Extracted from ``ChatView`` so that its accessibility contract
/// ("Error: <message>" header label) can be inspected directly in unit tests
/// without mounting a full `ChatViewModel` environment.
struct ErrorBannerView<Recovery: View>: View {

    /// Builds the VoiceOver label for an error banner. Kept as a static helper
    /// so tests can assert on the exact contract.
    static func accessibilityLabel(for error: ChatError) -> String {
        "Error: \(error.message)"
    }

    let error: ChatError
    let onDismiss: () -> Void
    let recoveryAction: () -> Recovery

    init(
        error: ChatError,
        onDismiss: @escaping () -> Void,
        @ViewBuilder recoveryAction: @escaping () -> Recovery
    ) {
        self.error = error
        self.onDismiss = onDismiss
        self.recoveryAction = recoveryAction
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            Text(error.message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            recoveryAction()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(12)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.top, 8)
        // Use .combine so that the container itself becomes the VoiceOver element.
        // With .contain the label/trait modifiers below would be silently ignored —
        // .contain exposes children individually and discards container-level overrides.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: error))
        .accessibilityAddTraits(.isHeader)
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
