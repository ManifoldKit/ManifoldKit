import SwiftUI
import ManifoldRuntime
import ManifoldInference

// MARK: - Chat Shell Body Pieces

struct ChatComposerSection: View {
    let accessoryBuilder: (() -> AnyView)?

    var body: some View {
        VStack(spacing: 0) {
            if let accessoryBuilder {
                accessoryBuilder()
            }
            ChatInputBar()
        }
    }
}

struct ChatUpgradeHintBanner: View {
    @Environment(\.manifoldTheme) private var theme
    @Binding var showModelManagement: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(theme.accent)
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
            .foregroundStyle(theme.accent)
            .accessibilityLabel("Browse models for extended context")
            .accessibilityIdentifier("chat-model-management-button")
        }
        .padding(12)
        .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.top, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct ChatLoadingContent: View {
    let activityPhase: BackendActivityPhase
    let unloadModel: () -> Void

    var body: some View {
        Group {
            if case .modelLoading(let progress) = activityPhase {
                ModelLoadingIndicatorView(progress: progress, onCancel: unloadModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct ChatNoModelLoadedContent: View {
    let appName: String
    let hasAvailableModels: Bool
    @Binding var showModelManagement: Bool

    var body: some View {
        if hasAvailableModels {
            modelSelectionPrompt
        } else {
            welcomePrompt
        }
    }

    private var welcomePrompt: some View {
        VStack(spacing: 20) {
            Image(systemName: "book.and.wrench")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Welcome to \(appName)")
                    .font(.title2.bold())

                Text("Download a model or add a cloud backend to get started.")
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
    }

    private var modelSelectionPrompt: some View {
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

// MARK: - Error Banner and Recovery

struct ChatErrorRecoveryBanner<APIConfig: View>: View {
    let viewModel: ChatViewModel
    @Binding var showAPIConfiguration: Bool
    @Binding var showModelManagement: Bool
    let apiConfigurationBuilder: () -> APIConfig

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(
        viewModel: ChatViewModel,
        showAPIConfiguration: Binding<Bool>,
        showModelManagement: Binding<Bool>,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) {
        self.viewModel = viewModel
        self._showAPIConfiguration = showAPIConfiguration
        self._showModelManagement = showModelManagement
        self.apiConfigurationBuilder = apiConfiguration
    }

    var body: some View {
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
                // so keep the banner alive until the popover dismisses.
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
            .popover(isPresented: Binding(
                get: { showAPIConfiguration && horizontalSizeClass == .regular },
                set: {
                    if !$0 {
                        showAPIConfiguration = false
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
}

/// Standalone chat error banner.
///
/// Extracted from ``ChatView`` so that its accessibility contract
/// ("Error: <message>" header label) can be inspected directly in unit tests
/// without mounting a full `ChatViewModel` environment.
struct ErrorBannerView<Recovery: View>: View {
    @Environment(\.manifoldTheme) private var theme

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
                .foregroundStyle(theme.statusWarn)
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
        .background(theme.statusError.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
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

// MARK: - Toolbar

struct ChatToolbarContent<APIConfig: View>: ToolbarContent {
    @Environment(\.manifoldTheme) private var theme
    let viewModel: ChatViewModel
    let features: ManifoldConfiguration.Features
    @Binding var isDeviceInfoExpanded: Bool
    @Binding var isSettingsPresented: Bool
    @Binding var isExportPresented: Bool
    @Binding var showClearConfirmation: Bool
    let apiConfigurationBuilder: () -> APIConfig

    init(
        viewModel: ChatViewModel,
        features: ManifoldConfiguration.Features,
        isDeviceInfoExpanded: Binding<Bool>,
        isSettingsPresented: Binding<Bool>,
        isExportPresented: Binding<Bool>,
        showClearConfirmation: Binding<Bool>,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) {
        self.viewModel = viewModel
        self.features = features
        self._isDeviceInfoExpanded = isDeviceInfoExpanded
        self._isSettingsPresented = isSettingsPresented
        self._isExportPresented = isExportPresented
        self._showClearConfirmation = showClearConfirmation
        self.apiConfigurationBuilder = apiConfiguration
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if viewModel.backendCapabilities?.isRemote == true,
               let backend = viewModel.activeBackendName {
                Label("Cloud", systemImage: "cloud.fill")
                    .font(.caption2)
                    .foregroundStyle(theme.accent)
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
        }
        ToolbarItem(placement: .automatic) {
            if features.showChatExport {
                exportButton
            }
        }
        ToolbarItem(placement: .automatic) {
            deviceInfoButton
        }
        ToolbarItem(placement: .automatic) {
            if features.showGenerationSettings {
                settingsButton
            }
        }
        ToolbarItem(placement: .automatic) {
            clearChatButton
        }
    }

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
            ChatDeviceInfoPopover(viewModel: viewModel)
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
        // Omitted on macOS to avoid conflicting with any host app's Settings scene.
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
}

struct ChatDeviceInfoPopover: View {
    @Environment(\.manifoldTheme) private var theme
    let viewModel: ChatViewModel

    var body: some View {
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
                    .foregroundStyle(viewModel.isModelLoaded ? theme.statusOK : theme.ink2)
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
}

// MARK: - Presentation Modifiers

private struct ChatShellPresentationModifier<APIConfig: View>: ViewModifier {
    let viewModel: ChatViewModel
    @Binding var showClearConfirmation: Bool
    @Binding var isSettingsPresented: Bool
    @Binding var isExportPresented: Bool
    let apiConfigurationBuilder: () -> APIConfig

    func body(content: Content) -> some View {
        let base = content.alert("Clear Chat", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await viewModel.clearChat() }
            }
        } message: {
            Text("This will delete all messages in the current chat. This cannot be undone.")
        }

        #if !os(iOS)
        return base
            .sheet(isPresented: $isSettingsPresented) {
                GenerationSettingsView(apiConfiguration: apiConfigurationBuilder)
            }
            .sheet(isPresented: $isExportPresented) {
                ChatExportSheet()
            }
        #else
        return base
        #endif
    }
}

private struct ChatAPIConfigurationPresentationModifier<APIConfig: View>: ViewModifier {
    @Binding var isPresented: Bool
    let apiConfigurationBuilder: () -> APIConfig

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        return content.sheet(isPresented: Binding(
            get: { isPresented && horizontalSizeClass == .compact },
            set: { if !$0 { isPresented = false } }
        )) {
            apiConfigurationBuilder()
                .presentationDragIndicator(.visible)
        }
        #else
        return content.sheet(isPresented: $isPresented) {
            apiConfigurationBuilder()
        }
        #endif
    }
}

extension View {
    func chatShellPresentations<APIConfig: View>(
        viewModel: ChatViewModel,
        showClearConfirmation: Binding<Bool>,
        isSettingsPresented: Binding<Bool>,
        isExportPresented: Binding<Bool>,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) -> some View {
        modifier(ChatShellPresentationModifier(
            viewModel: viewModel,
            showClearConfirmation: showClearConfirmation,
            isSettingsPresented: isSettingsPresented,
            isExportPresented: isExportPresented,
            apiConfigurationBuilder: apiConfiguration
        ))
    }

    func chatAPIConfigurationPresentation<APIConfig: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder apiConfiguration: @escaping () -> APIConfig
    ) -> some View {
        modifier(ChatAPIConfigurationPresentationModifier(
            isPresented: isPresented,
            apiConfigurationBuilder: apiConfiguration
        ))
    }
}
