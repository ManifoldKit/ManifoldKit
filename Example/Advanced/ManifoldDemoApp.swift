import SwiftUI
import SwiftData
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldUI
import ManifoldUIModelManagement
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldTools
#if canImport(ManifoldHuggingFace)
import ManifoldHuggingFace
#endif
#if canImport(AppIntents)
import ManifoldAppIntents
#endif

@main
struct ManifoldDemoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var chatViewModel: ChatViewModel?
    @State private var modelManagementViewModel: ModelManagementViewModel
    @State private var sessionManager = SessionManagerViewModel()
    @State private var runtime: ManifoldBootstrap?
    private let inferenceService: InferenceService
    private let toolApprovalGate: UIToolApprovalGate
    private let toolRegistry: ToolRegistry
    private let sandboxRoot: URL
    private let pendingDemoScenarioID: String?
    private let runtimeConfiguration: ManifoldConfiguration

    /// When `true`, the app was launched with `--uitesting` and should use
    /// an in-memory store, skip auto-model-load, and disable animations.
    private let isUITesting: Bool

    /// Single-slot buffer for inbound payloads that land during the
    /// cold-launch window where the runtime is still being assembled.
    /// ``DemoContentView`` drains it after the runtime-backed persistence is ready.
    @State private var pendingPayloadBuffer = PendingPayloadBuffer()

    /// Staged payload from the Share Extension or Action Extension, read out
    /// of App Group storage on each foreground transition. When the runtime is
    /// ready the payload is ingested immediately; otherwise it waits here until
    /// the bootstrap `Task` completes.
    @State private var stagedSharePayload: PendingSharePayload?

    init() {
        let testing = CommandLine.arguments.contains("--uitesting")
        self.isUITesting = testing

        let scenarioID = Self.demoScenarioID()
        self.pendingDemoScenarioID = scenarioID

        if testing {
            #if canImport(UIKit)
            UIView.setAnimationsEnabled(false)
            #endif
            // Default to a known state for UI tests that exercise the Advanced
            // Settings DisclosureGroup. macOS XCUITest has trouble synthesising
            // a click on the narrow chevron of a SwiftUI Form DisclosureTriangle
            // (the row is wide but only the leading glyph toggles), so tests
            // that need to reach Cloud API / Backend / Debug controls expect
            // the disclosure to start expanded.
            UserDefaults.standard.set(true, forKey: "showAdvancedSettings")
        }
        // Configure ManifoldKit for this app
        let runtimeConfiguration = ManifoldConfiguration(
            appName: "Manifold Demo",
            bundleIdentifier: "com.manifoldkit.demo"
        )
        self.runtimeConfiguration = runtimeConfiguration
        ManifoldConfiguration.shared = runtimeConfiguration

        // No curated model recommendations here: Advanced links no local-
        // inference companion (ManifoldMLX / ManifoldLlama), so every GGUF/MLX
        // curated entry that used to live here was unloadable — the model
        // registry could never resolve a registered backend for it (#2453 M2).
        // See Example/Examples/LocalInferenceExample/ for a curated MLX list
        // that actually works, in an app that links ManifoldMLX.

        // Sandbox root: under --uitesting we route writes (notably WriteFileTool)
        // into a per-launch temp directory so XCUITests leave no residue in
        // Application Support. Production runs use the long-lived demo root.
        let resolvedSandbox: URL = Self.resolveSandboxRoot(isTesting: testing)
        self.sandboxRoot = resolvedSandbox

        let registry = ToolRegistry()
        DemoTools.register(on: registry, root: resolvedSandbox)
        self.toolRegistry = registry

        let approvalGate = UIToolApprovalGate(policy: .askOncePerSession)
        self.toolApprovalGate = approvalGate

        let configuredService: InferenceService
        #if DEBUG
        if testing {
            // Under --uitesting, swap in a ScriptedBackend so the approval UI
            // can be exercised without live inference. The turn list is
            // scenario-aware: when --bck-demo-scenario is supplied the script
            // matches that scenario's expected tool-call shape; otherwise the
            // legacy fallback (sample_repo_search) preserves existing tests.
            let scripted = ScriptedBackend(turns: DemoScenarios.scriptedTurns(for: scenarioID))
            configuredService = InferenceService(
                backend: scripted,
                name: "ScriptedUITest",
                modelName: "scripted-ui",
                toolRegistry: registry,
                toolApprovalGate: approvalGate
            )
        } else {
            configuredService = InferenceService(
                toolRegistry: registry,
                toolApprovalGate: approvalGate
            )
            OllamaBackends.register(with: configuredService)
            CloudSaaSBackends.register(with: configuredService)
            FoundationBackends.register(with: configuredService)
        }
        #else
        configuredService = InferenceService(
            toolRegistry: registry,
            toolApprovalGate: approvalGate
        )
        OllamaBackends.register(with: configuredService)
        CloudSaaSBackends.register(with: configuredService)
        FoundationBackends.register(with: configuredService)
        #endif
        self.inferenceService = configuredService

        // ChatViewModel is constructed lazily in `installRuntime(using:)` once
        // the SwiftData container resolves — `conversationRuntime` is
        // constructor-injected and non-optional, so we cannot safely build a
        // view model before the runtime exists.
        _chatViewModel = State(initialValue: nil)

        #if canImport(ManifoldHuggingFace)
        let downloadManager = BackgroundDownloadManager()
        let hfService = HuggingFaceService()
        _modelManagementViewModel = State(initialValue: ModelManagementViewModel(
            huggingFaceService: hfService,
            downloadManager: downloadManager
        ))
        #else
        _modelManagementViewModel = State(initialValue: ModelManagementViewModel.live())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let runtime, let chatViewModel {
                    DemoContentView(
                        toolRegistry: toolRegistry,
                        sandboxRoot: sandboxRoot,
                        ragService: runtime.ragService,
                        sessionStore: runtime.persistence,
                        conversationRuntime: runtime.conversationRuntime,
                        pendingPayloadBuffer: pendingPayloadBuffer,
                        pendingDemoScenarioID: pendingDemoScenarioID
                    )
                    .environment(chatViewModel)
                    .environment(modelManagementViewModel)
                    .environment(sessionManager)
                    .environment(\.samplerPresetStore, runtime.samplerPresetStore)
                    .environment(\.personaStore, runtime.personaStore)
                    .environment(\.endpointStore, runtime.endpointStore)
                    #if os(macOS)
                    .frame(minWidth: 600, minHeight: 400)
                    #endif
                    .modelContainer(runtime.modelContainer)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task {
                            let testing = isUITesting

                            // Seed the pending buffer BEFORE the container
                            // finishes so `DemoContentView.onAppear` sees a
                            // non-empty buffer when it drains. Without this
                            // order, the `modelContainer = ...` assignment
                            // flips the view hierarchy to `DemoContentView`
                            // and its onAppear drains an empty buffer.
                            if testing, let seeded = Self.uiTestingSeededPayload() {
                                await pendingPayloadBuffer.store(seeded)
                            }

                            let container = await Task.detached(priority: .userInitiated) {
                                let config = ModelConfiguration("ManifoldDemo", isStoredInMemoryOnly: testing)
                                return try! ModelContainerFactory.makeContainer(configurations: [config])
                            }.value

                            installRuntime(using: container)
                        }
                }
            }
            .onOpenURL { url in
                handleOpenURL(url)
            }
            // Drain a staged share payload as soon as the SwiftData container
            // is ready. This covers the cold-launch race where scenePhase
            // fires .active before the container task completes. The `.task`
            // modifier lives on the inner View (not on `WindowGroup`, which
            // is a `Scene`).
            .task(id: runtime != nil ? 1 : 0) {
                guard runtime != nil, let chatViewModel, let staged = stagedSharePayload else { return }
                stagedSharePayload = nil
                guard let pendingPayload = pendingPayload(from: staged) else { return }
                await chatViewModel.ingestPendingPayload(pendingPayload, intent: .newSession(preset: nil))
            }
            // Wire the persisted appearance preference to SwiftUI's color-scheme
            // environment. SettingsService is @Observable so this re-evaluates
            // whenever appearanceMode changes — returning nil follows the OS setting.
            .preferredColorScheme(SettingsService.shared.appearanceMode.colorScheme)
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 700)
        #endif
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                checkForPendingSharePayload()
            }
        }
    }

    // MARK: - Inbound payload handoff

    /// Entry point for the `manifolddemo://ingest` URL scheme.
    ///
    /// Reads the JSON envelope the App Intent wrote to the App Group
    /// `UserDefaults`, decodes it back into an ``InboundPayload``, and
    /// either ingests immediately (if persistence is already wired) or
    /// buffers for ``DemoContentView`` to drain post-mount.
    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "manifolddemo", url.host == "ingest" else { return }
        guard let defaults = UserDefaults(suiteName: DemoAppGroup.identifier),
              let data = defaults.data(forKey: DemoAppGroup.inboundKey),
              let envelope = try? JSONDecoder().decode(InboundPayloadEnvelope.self, from: data) else {
            return
        }
        // Clear so we don't replay the same payload on the next launch.
        defaults.removeObject(forKey: DemoAppGroup.inboundKey)

        let payload = InboundPayload(
            prompt: envelope.prompt,
            attachments: envelope.attachments,
            source: decodeSource(envelope.source)
        )

        // If persistence is wired, ingest directly — otherwise hand off
        // to the buffer and let `DemoContentView` pick it up once mount
        // completes.
        if runtime != nil, let chatViewModel {
            Task { @MainActor in
                await chatViewModel.ingest(payload)
            }
        } else {
            Task {
                await pendingPayloadBuffer.store(payload)
            }
        }
    }

    // MARK: - Share / Action Extension handoff

    /// Reads and clears any ``PendingSharePayload`` written by the Share or
    /// Action Extension from the App Group container.
    ///
    /// Called on every foreground transition (`.onChange(of: scenePhase)`).
    /// When the runtime is ready the payload is passed to
    /// ``ChatViewModel/ingestPendingPayload(_:intent:)`` immediately;
    /// otherwise it is stored in ``stagedSharePayload`` and picked up by the
    /// `.task(id:)` modifier once bootstrap completes.
    private func checkForPendingSharePayload() {
        guard let defaults = UserDefaults(suiteName: DemoAppGroup.identifier),
              let data = defaults.data(forKey: DemoAppGroup.pendingShareKey),
              let sharePayload = try? JSONDecoder().decode(PendingSharePayload.self, from: data) else {
            return
        }
        // Remove before ingesting so a crash during ingest doesn't replay.
        defaults.removeObject(forKey: DemoAppGroup.pendingShareKey)

        if runtime != nil, let chatViewModel {
            guard let payload = pendingPayload(from: sharePayload) else { return }
            Task { @MainActor in
                await chatViewModel.ingestPendingPayload(payload, intent: .newSession(preset: nil))
            }
        } else {
            // Runtime still initialising — stage for the .task(id:) drain.
            stagedSharePayload = sharePayload
        }
    }

    @MainActor
    private func installRuntime(using container: ModelContainer) {
        // Pass an unconfigured `RAGConfiguration()` so the demo exercises the
        // keyword-fallback retrieval path even without a configured embedding
        // model. Hosts that want semantic search supply an `EmbeddingBackend`
        // here; without one, retrieval still runs on case-insensitive keyword
        // search via `FlatFileVectorStore.keywordSearch(query:limit:)`.
        let runtime = try! ManifoldBootstrap(
            configuration: runtimeConfiguration,
            ragConfiguration: RAGConfiguration(),
            inferenceService: inferenceService,
            makeModelContainer: { container }
        )

        let vm = ChatViewModel(
            inferenceService: inferenceService,
            toolApprovalGate: toolApprovalGate,
            conversationRuntime: runtime.conversationRuntime
        )
        vm.foundationModelProvider = {
            if #available(iOS 26, macOS 26, *) {
                return FoundationBackend.isAvailable
            }
            return false
        }
        vm.configure(bootstrap: runtime)
        sessionManager.configure(bootstrap: runtime)
        modelManagementViewModel.benchmarkCache = runtime.benchmarkCache
        // Use the runtime's classificationService so title generation routes
        // to the auxiliary backend (FoundationBackend on iOS 26+/macOS 26+)
        // rather than the user's chosen chat model.
        let classificationService = runtime.conversationRuntime.classificationService
        vm.onFirstMessage = { [classificationService, weak vm] session, text in
            guard let vm else { return }
            Task { @MainActor in
                while vm.isGenerating {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                await sessionManager.autoRenameSession(
                    session,
                    firstMessage: text,
                    inferenceService: classificationService
                )
            }
        }

        // Branch-origin chip (#2307) — resolves the display title once the
        // user is looking AT a branched session. `quickStart()` wires this
        // same one-liner; this app bootstraps manually so it wires it itself.
        vm.resolveBranchOriginTitle = { [weak sessionManager] session in
            await sessionManager?.branchOriginTitle(for: session)
        }

        // Session branching (#2453 turn-loop coverage): `ChatViewModel.branch(from:)`
        // creates and persists the new session but never switches the app TO
        // it — that's this closure's job. Without it, "Branch from here"
        // silently strands the user on the source session and the new
        // session only surfaces after an unrelated sidebar reload. Neither
        // this app nor `quickStart()` wired `onSessionBranched` before this
        // fix (`resolveBranchOriginTitle` above only renders the chip once
        // a branched session is already active — it doesn't get you there).
        vm.onSessionBranched = { [weak sessionManager] newSessionID in
            guard let sessionManager else { return }
            await sessionManager.loadSessions()
            if let newSession = sessionManager.sessions.first(where: { $0.id == newSessionID }) {
                sessionManager.activeSession = newSession
            }
        }

        if !isUITesting {
            vm.refreshModels()
            vm.autoSelectFirstRunModel()

            if vm.selectedModel == nil,
               let foundation = vm.availableModels.first(where: { $0.modelType == .foundation }) {
                vm.selectedModel = foundation
            }

            vm.dispatchSelectedLoad()
            vm.startMemoryMonitoring()
        }

        self.chatViewModel = vm
        self.runtime = runtime

        // Wire AskManifoldIntent so Siri / Shortcuts can route prompts
        // through the demo's inference service. The handler is a plain actor
        // adapter — no SwiftData or session dependency needed.
        #if canImport(AppIntents)
        if #available(iOS 18, macOS 15, *) {
            Task {
                await ManifoldIntentConfiguration.shared.configure(
                    handler: RuntimeHandler(inferenceService: inferenceService)
                )
            }
        }
        #endif
    }

    /// Converts a ``PendingSharePayload`` (pure Foundation, extension-safe)
    /// into a ``PendingPayload`` (ManifoldUI) for handoff to the view model.
    private func pendingPayload(from share: PendingSharePayload) -> PendingPayload? {
        switch share.kind {
        case .text:
            guard let text = share.text, !text.isEmpty else { return nil }
            return .text(text)
        case .url:
            guard let urlString = share.urlString, let url = URL(string: urlString) else { return nil }
            return .url(url)
        case .image:
            guard let data = share.imageData else { return nil }
            return .image(data, mimeType: share.imageMimeType ?? "image/png")
        }
    }

    private func decodeSource(_ raw: String) -> InboundPayload.Source {
        switch raw {
        case "deepLink": return .deepLink
        case "shareExtension": return .shareExtension
        case "appIntent": return .appIntent
        default:
            Log.ui.warning(
                "Unknown inbound-payload source '\(raw, privacy: .public)' — defaulting to .appIntent"
            )
            return .appIntent
        }
    }

    /// Returns a payload constructed from UI-testing launch arguments, if
    /// any. Used by ``AppIntentUITests`` to exercise the cold-launch
    /// handoff without invoking real AppIntents infrastructure.
    private static func uiTestingSeededPayload() -> InboundPayload? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--uitesting-ingest-prompt"),
              flagIndex + 1 < args.count else {
            return nil
        }
        return InboundPayload(prompt: args[flagIndex + 1], source: .appIntent)
    }

    /// Returns the demo-scenario ID supplied via `--bck-demo-scenario <id>`,
    /// or `nil` when no scenario was requested. Mirrors the
    /// `--uitesting`-flag pattern: simple positional value follows the flag.
    private static func demoScenarioID() -> String? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--bck-demo-scenario"),
              flagIndex + 1 < args.count else {
            return nil
        }
        return args[flagIndex + 1]
    }

    /// Resolves the demo sandbox root.
    ///
    /// UI tests may inject a fixed root via `MANIFOLD_DEMO_SANDBOX_ROOT` so
    /// they can assert side effects from `write_file`. Otherwise UI-testing
    /// launches use a disposable temp directory and production uses the
    /// long-lived Application Support root.
    private static func resolveSandboxRoot(isTesting: Bool) -> URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["MANIFOLD_DEMO_SANDBOX_ROOT"],
           !override.isEmpty {
            let root = URL(fileURLWithPath: override, isDirectory: true)
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                Log.ui.warning("Failed to create overridden demo sandbox at \(root.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return root
        }

        if isTesting {
            let tempRoot = fm.temporaryDirectory
                .appendingPathComponent("ManifoldDemo-UITest-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            } catch {
                Log.ui.warning("Failed to create UI-test sandbox at \(tempRoot.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return tempRoot
        }

        return DemoToolRoot.resolve()
    }
}
