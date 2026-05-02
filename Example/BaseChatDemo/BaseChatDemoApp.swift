import SwiftUI
import SwiftData
import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatUI
import BaseChatUIModelManagement
import BaseChatBackends
import BaseChatTools
#if canImport(BaseChatHuggingFace)
import BaseChatHuggingFace
#endif

@main
struct BaseChatDemoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var chatViewModel: ChatViewModel?
    @State private var modelManagementViewModel: ModelManagementViewModel
    @State private var sessionManager = SessionManagerViewModel()
    @State private var runtime: BaseChatBootstrap?
    private let inferenceService: InferenceService
    private let toolApprovalGate: UIToolApprovalGate
    private let toolRegistry: ToolRegistry
    private let sandboxRoot: URL
    private let pendingDemoScenarioID: String?
    private let runtimeConfiguration: BaseChatConfiguration

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
        // Configure BaseChatKit for this app
        let runtimeConfiguration = BaseChatConfiguration(
            appName: "BaseChat Demo",
            bundleIdentifier: "com.basechatkit.demo"
        )
        self.runtimeConfiguration = runtimeConfiguration
        BaseChatConfiguration.shared = runtimeConfiguration

        // Populate curated model recommendations
        CuratedModel.all = Self.curatedModels

        // Sandbox root: under --uitesting we route writes (notably WriteFileTool)
        // into a per-launch temp directory so XCUITests leave no residue in
        // Application Support. Production runs use the long-lived demo root.
        let resolvedSandbox: URL = {
            if testing {
                let tempRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("BaseChatDemo-UITest-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                return tempRoot
            }
            return DemoToolRoot.resolve()
        }()
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
            DefaultBackends.register(with: configuredService)
        }
        #else
        configuredService = InferenceService(
            toolRegistry: registry,
            toolApprovalGate: approvalGate
        )
        DefaultBackends.register(with: configuredService)
        #endif
        self.inferenceService = configuredService

        // ChatViewModel is constructed lazily in `installRuntime(using:)` once
        // the SwiftData container resolves — `conversationRuntime` is
        // constructor-injected and non-optional, so we cannot safely build a
        // view model before the runtime exists.
        _chatViewModel = State(initialValue: nil)

        #if canImport(BaseChatHuggingFace)
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

    // MARK: - Curated Models

    private static let curatedModels: [CuratedModel] = [
        // Small — runs on any Apple Silicon device (≤ 2.5 GB)
        CuratedModel(
            id: "smollm2-360m",
            displayName: "SmolLM2 360M (Q8)",
            fileName: "smollm2-360m-instruct-q8_0.gguf",
            repoID: "HuggingFaceTB/SmolLM2-360M-Instruct-GGUF",
            modelType: .gguf,
            approximateSizeBytes: 386_000_000,
            recommendedFor: [.small, .medium, .large, .xlarge],
            contextSize: 2048,
            promptTemplate: .chatML,
            description: "Tiny but capable chat model, great for testing"
        ),
        CuratedModel(
            id: "phi-4-mini-mlx",
            displayName: "Phi-4 Mini (MLX, 4-bit)",
            fileName: "Phi-4-mini-instruct-4bit",
            repoID: "mlx-community/Phi-4-mini-instruct-4bit",
            modelType: .mlx,
            approximateSizeBytes: 2_400_000_000,
            recommendedFor: [.small, .medium, .large, .xlarge],
            contextSize: 4096,
            promptTemplate: .phi,
            description: "Microsoft's compact reasoning model, optimized for Apple Silicon"
        ),
        // Medium — 8 GB+ RAM devices (≤ 4.5 GB)
        CuratedModel(
            id: "mistral-7b-gguf",
            displayName: "Mistral 7B Instruct v0.3 (Q4_K_M)",
            fileName: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
            repoID: "bartowski/Mistral-7B-Instruct-v0.3-GGUF",
            modelType: .gguf,
            approximateSizeBytes: 4_370_000_000,
            recommendedFor: [.medium, .large, .xlarge],
            contextSize: 4096,
            promptTemplate: .mistral,
            description: "Excellent general-purpose chat model"
        ),
        CuratedModel(
            id: "llama-3.2-3b-mlx",
            displayName: "Llama 3.2 3B Instruct (MLX, 4-bit)",
            fileName: "Llama-3.2-3B-Instruct-4bit",
            repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            modelType: .mlx,
            approximateSizeBytes: 1_800_000_000,
            recommendedFor: [.small, .medium, .large, .xlarge],
            contextSize: 8192,
            promptTemplate: .llama3,
            description: "Meta's efficient 3B model with 8K context"
        ),
        // Large — 16 GB+ RAM devices (≤ 6 GB)
        CuratedModel(
            id: "qwen-2.5-7b-mlx",
            displayName: "Qwen 2.5 7B Instruct (MLX, 4-bit)",
            fileName: "Qwen2.5-7B-Instruct-4bit",
            repoID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            modelType: .mlx,
            approximateSizeBytes: 4_500_000_000,
            recommendedFor: [.large, .xlarge],
            contextSize: 8192,
            promptTemplate: .chatML,
            description: "Strong multilingual model from Alibaba"
        ),
    ]

    var body: some Scene {
        WindowGroup {
            Group {
                if let runtime, let chatViewModel {
                    DemoContentView(
                        toolRegistry: toolRegistry,
                        sandboxRoot: sandboxRoot,
                        pendingPayloadBuffer: pendingPayloadBuffer,
                        pendingDemoScenarioID: pendingDemoScenarioID
                    )
                    .environment(chatViewModel)
                    .environment(modelManagementViewModel)
                    .environment(sessionManager)
                    .environment(\.samplerPresetStore, runtime.samplerPresetStore)
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
                                let config = ModelConfiguration("BaseChatDemo", isStoredInMemoryOnly: testing)
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

    /// Entry point for the `basechatdemo://ingest` URL scheme.
    ///
    /// Reads the JSON envelope the App Intent wrote to the App Group
    /// `UserDefaults`, decodes it back into an ``InboundPayload``, and
    /// either ingests immediately (if persistence is already wired) or
    /// buffers for ``DemoContentView`` to drain post-mount.
    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "basechatdemo", url.host == "ingest" else { return }
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
        let runtime = try! BaseChatBootstrap(
            configuration: runtimeConfiguration,
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
        vm.configure(runtime: runtime)
        sessionManager.configure(runtime: runtime)
        modelManagementViewModel.benchmarkCache = runtime.benchmarkCache
        vm.onFirstMessage = { [inferenceService, weak vm] session, text in
            guard let vm else { return }
            Task { @MainActor in
                while vm.isGenerating {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                await sessionManager.autoRenameSession(
                    session,
                    firstMessage: text,
                    inferenceService: inferenceService
                )
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
    }

    /// Converts a ``PendingSharePayload`` (pure Foundation, extension-safe)
    /// into a ``PendingPayload`` (BaseChatUI) for handoff to the view model.
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
}
