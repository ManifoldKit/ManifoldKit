import SwiftUI
import SwiftData
import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatUI
import BaseChatUIModelManagement
import BaseChatBackends
#if canImport(BaseChatHuggingFace)
import BaseChatHuggingFace
#endif

/// The simplest possible BaseChatKit app with runtime-first bootstrap.
///
/// This assembles a ``BaseChatBootstrap``, registers the built-in backends,
/// and presents the standard chat + model-management surfaces.
@main
struct MinimalExampleApp: App {
    private let runtime: BaseChatBootstrap
    @State private var chatViewModel: ChatViewModel
    @State private var sessionManager: SessionManagerViewModel
    @State private var modelManagement: ModelManagementViewModel

    init() {
        // Building the runtime — and therefore the SwiftData container — in
        // App.init() is fine here because the Minimal example uses a small
        // schema. For larger schemas, prefer building the container in a
        // detached `.task` (see BaseChatDemoApp): SwiftData container setup
        // (schema compilation + SQLite open) can stall the first frame for
        // several seconds when done on the main thread.
        let runtime = try! BaseChatBootstrap(
            configuration: BaseChatConfiguration(
                appName: "Minimal Chat",
                bundleIdentifier: "com.basechatkit.minimal-example"
            )
        )
        self.runtime = runtime

        DefaultBackends.register(with: runtime.inferenceService)

        let vm = ChatViewModel(
            inferenceService: runtime.inferenceService,
            conversationRuntime: runtime.conversationRuntime
        )
        vm.foundationModelProvider = {
            if #available(iOS 26, macOS 26, *) {
                return FoundationBackend.isAvailable
            }
            return false
        }
        vm.configure(runtime: runtime)
        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(runtime: runtime)

        _chatViewModel = State(initialValue: vm)
        _sessionManager = State(initialValue: sessionManager)
        #if canImport(BaseChatHuggingFace)
        let downloadManager = BackgroundDownloadManager()
        let huggingFaceService = HuggingFaceService()
        let modelManagement = ModelManagementViewModel(
            huggingFaceService: huggingFaceService,
            downloadManager: downloadManager
        )
        #else
        let modelManagement = ModelManagementViewModel.live()
        #endif
        modelManagement.benchmarkCache = runtime.benchmarkCache
        _modelManagement = State(initialValue: modelManagement)
    }

    var body: some Scene {
        WindowGroup {
            MinimalContentView()
                .environment(chatViewModel)
                .environment(sessionManager)
                .environment(modelManagement)
                .environment(\.samplerPresetStore, runtime.samplerPresetStore)
                .environment(\.endpointStore, runtime.endpointStore)
                .task {
                    // SwiftData fetches and the initial model load run here
                    // rather than in App.init(): the @MainActor work below
                    // touches the persistent store, and doing it during
                    // initialiser execution stalls the first frame.
                    await bootstrapInitialSession()
                }
        }
        .modelContainer(runtime.modelContainer)
    }

    @MainActor
    private func bootstrapInitialSession() async {
        chatViewModel.refreshModels()
        // Phase 1.0: `configure` no longer auto-loads. Pull the first page
        // here so an existing-session check sees the persisted list.
        await sessionManager.loadSessions()

        let initialSession: ChatSessionRecord?
        if let existing = sessionManager.sessions.first {
            initialSession = existing
        } else {
            initialSession = try? await sessionManager.createSession()
        }
        if let initialSession {
            sessionManager.activeSession = initialSession
            await chatViewModel.switchToSession(initialSession)
            chatViewModel.dispatchSelectedLoad()
        }
    }
}
