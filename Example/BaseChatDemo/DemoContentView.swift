import SwiftUI
import SwiftData
import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatUI
import BaseChatUIModelManagement
import BaseChatVoice

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
    // BaseChatVoice's AppleSpeechTranscriber drives AVAudioEngine, which raises
    // on iOS Simulator launch (no audio input device). Mount the controller
    // and the composer accessory only on real hardware.
    #if !targetEnvironment(simulator)
    @State private var voiceController = VoiceConversationController(
        wakeWordDetector: AppleWakeWordDetector(wakeWords: ["hey base chat", "base chat"])
    )
    #endif

    /// Tool registry shared with the app's inference service. Held here so the
    /// demo scenario runner can install scenario-specific variant executors.
    let toolRegistry: ToolRegistry

    /// Sandbox root the demo's filesystem tools resolve paths against. Held
    /// here (rather than re-resolved per-scenario) so `--uitesting` runs use
    /// a stable temp directory the test harness can inspect.
    let sandboxRoot: URL

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
            ChatView(
                showModelManagement: $isModelManagementPresented,
                emptyState: { ChatEmptyStateView(runScenario: runScenario) },
                composerAccessory: {
                    #if !targetEnvironment(simulator)
                    VoiceComposerAccessory(controller: voiceController)
                    #else
                    EmptyView()
                    #endif
                },
                apiConfiguration: { APIConfigurationView() }
            )
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
                }
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
            // Probe the active backend by name. ``ModelLifecycleCoordinator``
            // labels the Foundation Models backend "Apple"; matching that
            // string keeps the demo independent of `import BaseChatBackends`.
            ConnectedServicesView(
                toolRegistry: toolRegistry,
                isFoundationModelsActive: { viewModel.activeBackendName == "Apple" }
            )
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
                // resolved to a scenario in `BaseChatDemoApp.init()` and
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
                    Task { await viewModel.switchToSession(session) }
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
                            if viewModel.activeBackendName == "Apple" { return "Apple Intelligence" }
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
                sandboxRoot: sandboxRoot
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
            get: { (viewModel.toolApprovalGate?.pending.first) != nil },
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

    private func policyLabel(_ policy: UIToolApprovalGate.Policy) -> String {
        switch policy {
        case .alwaysAsk: return "Always ask"
        case .askOncePerSession: return "Once / session"
        case .autoApprove: return "Auto"
        }
    }
}
