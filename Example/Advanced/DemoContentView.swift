import SwiftUI
import SwiftData
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldUI
import ManifoldUIModelManagement
import ManifoldVoice

struct DemoContentView: View {
    @Environment(ChatViewModel.self) private var viewModel
    @Environment(ModelManagementViewModel.self) private var managementViewModel
    @Environment(SessionManagerViewModel.self) private var sessionManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Query(filter: #Predicate<APIEndpoint> { $0.isEnabled }, sort: \APIEndpoint.createdAt)
    private var cloudEndpoints: [APIEndpoint]

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var isModelManagementPresented = false
    @State private var isToolPolicyPresented = false
    @State private var isConnectedServicesPresented = false
    @State private var isDocumentLibraryPresented = false
    // Worked example of the ManifoldUI theming seams. Defaults to `.standard`
    // so the demo's stock appearance is unchanged until the user switches via
    // the "Appearance" menu — which doubles as a runtime theme-switching demo.
    @State private var demoTheme: DemoChatTheme = .standard
    // ManifoldVoice's AppleSpeechTranscriber drives AVAudioEngine, which raises
    // on iOS Simulator launch (no audio input device). Mount the controller
    // and the composer accessory only on real hardware.
    #if !targetEnvironment(simulator)
    @State private var voiceController = VoiceConversationController()
    #endif

    /// Tool registry shared with the app's inference service. Held here so the
    /// demo scenario runner can install scenario-specific variant executors.
    let toolRegistry: ToolRegistry

    /// Sandbox root the demo's filesystem tools resolve paths against. Held
    /// here (rather than re-resolved per-scenario) so `--uitesting` runs use
    /// a stable temp directory the test harness can inspect.
    let sandboxRoot: URL

    /// The RAG knowledge-base service. Forwarded into ``DocumentLibrarySheet``
    /// when the user opens the sidebar's "Knowledge Base" entry. `nil` when
    /// the demo bootstraps without ``RAGConfiguration``.
    let ragService: RAGService?

    /// Optional session store used by ``DemoScenarioRunner`` to persist
    /// scenario-provided agents/`activeAgentID` onto the freshly-created
    /// session before the first prompt runs. When `nil`, scenarios that
    /// populate ``DemoScenarioRuntimeContext/agents`` no-op the persistence
    /// step (the demo still runs, just without per-agent rendering).
    var sessionStore: (any SessionStore)?

    /// The live ``ConversationRuntime`` the demo built at app init. The
    /// scenario runner rebinds the runtime's per-session knobs
    /// (``ConversationRuntime/updateSessionToolSources(_:)`` /
    /// ``ConversationRuntime/updateHookRegistry(_:)``) per scenario card
    /// rather than rebuilding the runtime — same instance, swapped
    /// bindings.
    var conversationRuntime: ConversationRuntime?

    /// Buffer holding any ``InboundPayload`` that arrived during the
    /// cold-launch window, before the runtime finished bootstrapping.
    /// Drained once the mounted view can safely hand off to `ChatViewModel`.
    var pendingPayloadBuffer: PendingPayloadBuffer?

    /// Optional demo-scenario ID supplied via `--bck-demo-scenario`. Resolved
    /// to a ``DemoScenario`` and run after the runtime-backed persistence is ready.
    var pendingDemoScenarioID: String?

    var body: some View {
        // Read the gate's pending queue so SwiftUI observes changes and the
        // `.sheet(item:)` binding below re-evaluates when a new approval
        // is enqueued. Without this the binding's `get` closure is stale.
        let _ = viewModel.toolApprovalGate?.pending.count

        return NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            sidebar
        } detail: {
            detailColumn
        }
        .sheet(isPresented: $isModelManagementPresented) {
            ModelManagementSheet(modelRegistry: viewModel.modelRegistry)
                .environment(managementViewModel)
        }
        .sheet(isPresented: $isToolPolicyPresented) {
            ToolPolicyView()
                .environment(viewModel)
        }
        .sheet(isPresented: $isConnectedServicesPresented) {
            ConnectedServicesView(
                toolRegistry: toolRegistry,
                isFoundationModelsActive: {
                    viewModel.activeBackendName == BackendName.foundation.rawValue
                }
            )
        }
        .sheet(isPresented: $isDocumentLibraryPresented) {
            // The demo wires `RAGConfiguration()` with no host-injected embedding
            // backend, so `ManifoldBootstrap` falls back to the bundled
            // `NLEmbeddingBackend` — retrieval is actually semantic, not
            // keyword-fallback. Omit `hasEmbeddingBackend` entirely so the sheet
            // derives the banner from `RAGService.usesSemanticRetrieval` instead
            // of asserting the opposite of what the code does.
            DocumentLibrarySheet(ragService: ragService)
        }
        .sheet(isPresented: approvalSheetIsPresented) {
            if let call = viewModel.toolApprovalGate?.pending.first {
                ToolApprovalSheet(call: call)
                    .environment(viewModel)
            } else {
                // Belt-and-braces: the binding only flips to `true` when
                // ``pending.first`` exists, but a race during dismiss can
                // leave the queue empty while the sheet closes. Emit a
                // drop-down so we don't present an empty sheet shell.
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .overlay {
            if usesInlineApprovalForUITesting,
               let call = viewModel.toolApprovalGate?.pending.first {
                ToolApprovalSheet(call: call)
                    .environment(viewModel)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 12)
                    .padding()
            }
        }
        .onAppear {
            if horizontalSizeClass == .compact {
                columnVisibility = .detailOnly
                preferredCompactColumn = .detail
            }

            viewModel.setAvailableEndpoints(cloudEndpoints.map(\.record))

            // Seed an empty session and/or drain any buffered payload.
            //
            // On cold-launch with a pending payload, `ingest(_:)` will create
            // its own session — seeding an empty one here would leave an orphan
            // in the sidebar (#677). We peek at the buffer before deciding
            // whether to create the placeholder session.
            Task { @MainActor in
                let hasPendingPayload = await pendingPayloadBuffer?.peek() != nil

                // Phase 1.0: `configure(runtime:)` no longer auto-fires
                // `loadSessions()`. Pull the first page here so the
                // empty-state check below sees the actual persisted list,
                // not the pre-load empty state. Safe to call alongside the
                // sidebar's own `.task { }` load — main-actor serialisation
                // makes the second call a no-op against the in-memory state.
                await sessionManager.loadSessions()

                if !hasPendingPayload && sessionManager.sessions.isEmpty {
                    do {
                        try await sessionManager.createSession()
                    } catch {
                        viewModel.errorMessage = "Failed to create session: \(error.localizedDescription)"
                    }
                }

                // On first launch, createSession() above activates the new session.
                // On subsequent launches, sessions already exist but none is active
                // yet — restore the most recent one so the chat detail is ready
                // immediately without waiting for the user to tap a row in the sidebar.
                if sessionManager.activeSession == nil, let first = sessionManager.sessions.first {
                    sessionManager.activeSession = first
                }

                // Drain any payload that arrived during the cold-launch window
                // where the runtime was not ready yet.
                if let pendingPayloadBuffer, let payload = await pendingPayloadBuffer.drain() {
                    await viewModel.ingest(payload)
                }

                // Demo-scenario cold-launch path — `--bck-demo-scenario <id>`
                // resolved to a scenario in `ManifoldDemoApp.init()` and
                // forwarded here. Runs *after* the empty initial-session
                // seeding above so the scenario's session becomes the active
                // one rather than competing with a placeholder.
                if let id = pendingDemoScenarioID, let scenario = DemoScenarios.scenario(id: id) {
                    runScenario(scenario)
                }
            }
        }
        .onChange(of: viewModel.selectedModel) {
            viewModel.dispatchSelectedLoad()
        }
        .onChange(of: viewModel.selectedEndpoint) {
            viewModel.dispatchSelectedLoad()
        }
        .onChange(of: cloudEndpoints) {
            viewModel.setAvailableEndpoints(cloudEndpoints.map(\.record))
        }
        .onChange(of: sessionManager.activeSession) { _, newSession in
            if let session = newSession {
                if horizontalSizeClass == .compact {
                    columnVisibility = .detailOnly
                    preferredCompactColumn = .detail
                }
                // Guard against the back-channel loop with `onChange(of:
                // viewModel.activeSession)` below: when `ingest(_:)` creates
                // a session and switches `viewModel` to it, the sibling
                // handler mirrors the change into `sessionManager`, which
                // would re-enter `switchToSession` here and (because
                // `isGenerating` is already `true`) call `stopGeneration()`
                // mid-stream, wiping the ingested reply. Only re-activate
                // if the view model is currently on a different session.
                if viewModel.activeSession?.id != session.id {
                    // Consuming (rather than just reading) clears the target
                    // so re-activating the same session later — an ordinary
                    // open — does not re-trigger the jump.
                    let scrollTarget = sessionManager.consumeSearchScrollTarget(for: session.id)
                    Task { await viewModel.switchToSession(session, scrollToMessageID: scrollTarget) }
                }
            }
        }
        .onChange(of: viewModel.activeSession) { _, newSession in
            // Keep `SessionManagerViewModel.activeSession` in sync when
            // `ChatViewModel.ingest(_:)` creates + switches to a new
            // session of its own. Without this, the sidebar binding
            // stays on whatever session was previously active and the
            // user sees the wrong detail pane.
            guard let newSession else { return }
            if sessionManager.activeSession?.id != newSession.id {
                Task { await sessionManager.loadSessions() }
                sessionManager.activeSession = newSession
            }
        }
        .onChange(of: managementViewModel.completedDownloadCount) { _, _ in
            viewModel.refreshModels()
        }
    }

    /// The detail-column view chain, extracted from `body` because the
    /// combined NavigationSplitView expression exceeded the type-checker
    /// budget under xcodebuild (swift build never compiles this target).
    private var detailColumn: some View {
        ChatView(showModelManagement: $isModelManagementPresented)
            .chatEmptyState { ChatEmptyStateView(runScenario: runScenario) }
            // Worked example of the quick model-switcher chip (Unit 2 §L5,
            // issue #2307) — `ChatView` owns only the chrome (toolbar chip,
            // popover/sheet); the content is supplied here because the
            // unified row list needs `ManifoldUIModelManagement` types
            // `ManifoldUI` cannot import. Must be applied while the receiver
            // is still `ChatView` — the seam methods chain on the concrete
            // type, so this sits with its sibling seams, before `.chatTheme`
            // decays the chain to `some View`. `onSelect` only sets the
            // selection; the `.onChange` handlers below own dispatch.
            .chatModelSwitcher { modelSwitcherContent }
                .chatComposerAccessory {
                    #if !targetEnvironment(simulator)
                    VoiceComposerAccessory(controller: voiceController)
                    #else
                    EmptyView()
                    #endif
                }
                .chatAPIConfiguration { APIConfigurationView() }
                // Theming, all three layers composed: Layer 1 tokens via
                // `.chatTheme(_:)`, Layer 2 bubble chrome via
                // `.messageBubbleStyle(_:)`, Layer 3 per-message override via
                // `.chatMessageRenderer(_:)`. Each is read from the single
                // `demoTheme` selection so flipping the Appearance menu restyles
                // the live transcript without rebuilding the view.
                .chatTheme(demoTheme.theme)
                .modifier(DemoBubbleStyleModifier(theme: demoTheme))
                .chatMessageRenderer { params in
                    // Override only system notices with a compact pill; defer
                    // every other message to the built-in, fully-themed bubble.
                    if params.message.role == .system {
                        AnyView(DemoSystemNotice(text: params.message.content))
                    } else {
                        params.defaultMessageView()
                    }
                }
                .toolbar {
                    // .topBarLeading is iOS-only; macOS NavigationSplitView manages
                    // sidebar visibility via its own controls so this button is not
                    // needed on macOS. (#375)
                    #if os(iOS)
                    if horizontalSizeClass == .compact {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                preferredCompactColumn = .sidebar
                            } label: {
                                Label("Show Sidebar", systemImage: "sidebar.leading")
                            }
                            .accessibilityLabel("Show Sidebar")
                            .accessibilityIdentifier("show-sidebar-button")
                        }
                    }
                    #endif
                    // `.secondaryAction` sends the appearance picker into the
                    // overflow menu, keeping the compact-width bar lean enough
                    // that the model-switcher chip renders directly in the bar
                    // (#2307 — a chip collapsed into the overflow menu renders
                    // but its row does not activate; keep host bars lean).
                    ToolbarItem(placement: .secondaryAction) {
                        Menu {
                            Picker("Appearance", selection: $demoTheme) {
                                ForEach(DemoChatTheme.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                        } label: {
                            Label("Appearance", systemImage: "paintpalette")
                        }
                        .accessibilityIdentifier("demo-appearance-menu")
                    }
                }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if horizontalSizeClass == .compact {
                Button(action: createSession) {
                    Label("New Chat", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .accessibilityLabel("New Chat")
                .accessibilityIdentifier("new-chat-button")
            }

            SessionListView()

            Divider()

            // Simple model section
            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    isModelManagementPresented = true
                } label: {
                    HStack {
                        // When the Apple Foundation Models backend is active there is
                        // no user-selected local model, so selectedModel is nil — but
                        // the engine is running and "No Model Selected" would be wrong.
                        let modelLabel: String = {
                            if let name = viewModel.selectedModel?.name { return name }
                            if viewModel.activeBackendName == BackendName.foundation.rawValue {
                                return "Apple Intelligence"
                            }
                            return "No Model Selected"
                        }()
                        Text(modelLabel)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar-model-management-button")

                if viewModel.isModelLoaded {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if viewModel.isLoading {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Loading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if viewModel.activeError != nil {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    isToolPolicyPresented = true
                } label: {
                    HStack {
                        Label("Tool approval", systemImage: "checkmark.shield")
                            .font(.caption)
                        Spacer()
                        Text(policyLabel(viewModel.toolApprovalPolicy))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar-tool-policy-button")

                Button {
                    isConnectedServicesPresented = true
                } label: {
                    HStack {
                        Label("Connected Services", systemImage: "link.badge.plus")
                            .font(.caption)
                        Spacer()
                        Text("Manage")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar-connected-services-button")

                Button {
                    isDocumentLibraryPresented = true
                } label: {
                    HStack {
                        Label("Knowledge Base", systemImage: "books.vertical")
                            .font(.caption)
                        Spacer()
                        Text("Manage")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar-knowledge-base-button")
            }
            .padding()
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: toolbarPlacement) {
                Button(action: createSession) {
                    Label("New Chat", systemImage: "plus")
                }
                .accessibilityLabel("New Chat")
                .accessibilityIdentifier("new-chat-button")
                // Cmd+N is the system convention for "new document/item" on both
                // macOS and iPadOS with a hardware keyboard.
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: toolbarPlacement) {
                Menu {
                    ForEach(DemoScenarios.all) { scenario in
                        Button {
                            runScenario(scenario)
                        } label: {
                            Label(scenario.title, systemImage: scenario.systemImage)
                        }
                        .accessibilityIdentifier("demo-menu-\(scenario.id)")
                    }
                } label: {
                    Label("Demos", systemImage: "sparkles")
                }
                .accessibilityLabel("Demo scenarios")
                .accessibilityIdentifier("demos-menu-button")
                .disabled(viewModel.isGenerating)
            }
        }
    }

    private func createSession() {
        Task {
            do {
                try await sessionManager.createSession()
            } catch {
                viewModel.errorMessage = "Failed to create session: \(error.localizedDescription)"
            }
        }
    }

    /// Closure passed down to `ChatEmptyStateView` and the `Demos` toolbar
    /// menu so both surfaces share the runner.
    private func runScenario(_ scenario: DemoScenario) {
        Task { @MainActor in
            await DemoScenarioRunner.run(
                scenario,
                chat: viewModel,
                sessions: sessionManager,
                registry: toolRegistry,
                sandboxRoot: sandboxRoot,
                sessionStore: sessionStore,
                conversationRuntime: conversationRuntime
            )
        }
    }

    private var toolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }

    /// Drives the presentation of the approval sheet off the gate's pending
    /// queue. Kept as a computed `Binding<Bool>` so `@Observable` tracking on
    /// the gate re-evaluates the binding whenever the queue mutates — a
    /// `.sheet(item:)` binding with `Binding(get:set:)` would not re-read
    /// without another observed property driving the re-render.
    private var approvalSheetIsPresented: Binding<Bool> {
        Binding(
            get: {
                !usesInlineApprovalForUITesting
                    && (viewModel.toolApprovalGate?.pending.first) != nil
            },
            set: { newValue in
                guard !newValue else { return }
                // Drag-dismiss (iOS) is a dismiss without an explicit
                // decision; treat it as a denial so the pending queue
                // drains and the model recovers with a structured error.
                if let first = viewModel.toolApprovalGate?.pending.first {
                    viewModel.toolApprovalGate?.resolve(
                        callId: first.id,
                        with: .denied(reason: "dismissed")
                    )
                }
            }
        )
    }

    private var usesInlineApprovalForUITesting: Bool {
        ProcessInfo.processInfo.environment["MANIFOLD_DEMO_INLINE_APPROVAL"] == "1"
    }

    /// The unified local-model + cloud-endpoint row list fed to the
    /// `.chatModelSwitcher(_:)` chip. `compatibility` reads
    /// `ModelRegistry.compatibility(for:)` (public, reflects live backend
    /// registration) rather than standing up a separate capability-service
    /// instance — the same source `ModelPicker`/`ModelManagementSheet`
    /// already read.
    /// The `.chatModelSwitcher(_:)` content, extracted so the main body
    /// expression stays within the type-checker's budget. `onSelect` only
    /// sets the selection property — the `.onChange` handlers own dispatch
    /// (see docs/MIGRATION-ui-refresh.md's onSelect contract).
    private var modelSwitcherContent: some View {
        ModelSwitcherView(
            rows: modelSwitcherRows,
            onSelect: { (entry: ModelSwitcherEntry) in
                switch entry {
                case .model(let model):
                    viewModel.selectedModel = model
                case .endpoint(let endpoint):
                    viewModel.selectedEndpoint = endpoint
                }
            },
            onFixEndpoint: { _ in isModelManagementPresented = true }
        )
    }

    private var modelSwitcherRows: [ModelSwitcherRow] {
        ModelSwitcher.rows(
            models: viewModel.availableModels,
            endpoints: viewModel.availableEndpoints,
            selectedModelID: viewModel.selectedModel?.id,
            selectedEndpointID: viewModel.selectedEndpoint?.id,
            physicalMemoryBytes: viewModel.physicalMemoryBytes,
            compatibility: viewModel.modelRegistry.compatibility(for:)
        )
    }

    private func policyLabel(_ policy: UIToolApprovalGate.Policy) -> String {
        switch policy {
        case .alwaysAsk: return "Always ask"
        case .askOncePerSession: return "Once / session"
        case .askOncePerTool: return "Once / tool"
        case .autoApprove: return "Auto"
        }
    }
}

// MARK: - Theming demo

/// The Appearance options surfaced in the demo's detail toolbar. Each case maps
/// to a ``ChatTheme`` (Layer 1) and a ``MessageBubbleStyle`` (Layer 2). This is
/// the worked example for issue #1640 — a host wiring the in-framework theming
/// seams instead of forking the chat view.
enum DemoChatTheme: String, CaseIterable, Identifiable {
    case standard
    case brand
    case iMessage
    case card

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .brand: "Brand"
        case .iMessage: "iMessage"
        case .card: "Card"
        }
    }

    /// Layer 1 tokens. `.standard` returns the framework default so the demo's
    /// stock look is byte-for-byte unchanged; `.brand` overrides colors and
    /// metrics while leaving fonts as Dynamic-Type-safe text styles.
    var theme: ChatTheme {
        switch self {
        case .standard, .iMessage, .card:
            ChatTheme.standard
        case .brand:
            ChatTheme(
                userBubbleBackground: AnyShapeStyle(Color.indigo.gradient),
                assistantBubbleBackground: AnyShapeStyle(.fill.quaternary),
                cornerRadius: 22,
                bubblePadding: 14
            )
        }
    }
}

/// Applies the Layer-2 bubble style for the selected ``DemoChatTheme``.
///
/// A `ViewModifier` (rather than an inline `.messageBubbleStyle(_:)`) because the
/// modifier is generic over a concrete style type — switching among the built-ins
/// needs a `@ViewBuilder` branch so each concrete style is applied on its own
/// path.
struct DemoBubbleStyleModifier: ViewModifier {
    let theme: DemoChatTheme

    @ViewBuilder
    func body(content: Content) -> some View {
        switch theme {
        case .standard, .brand:
            content.messageBubbleStyle(.plain)
        case .iMessage:
            content.messageBubbleStyle(.iMessage)
        case .card:
            content.messageBubbleStyle(.card)
        }
    }
}

/// Layer-3 override: a compact pill for system notices, demonstrating that a
/// `.chatMessageRenderer` can take over *some* messages and defer the rest.
struct DemoSystemNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.fill.quaternary, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            // The built-in bubble supplies its own VoiceOver label; a full Layer-3
            // replacement must restore the accessibility contract itself.
            .accessibilityLabel("System said: \(text)")
    }
}
