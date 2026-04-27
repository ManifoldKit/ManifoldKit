import SwiftUI
import SwiftData
import BaseChatCore
import BaseChatInference
import BaseChatUI
import BaseChatUIModelManagement
import BaseChatBackends

/// The simplest possible BaseChatKit app with runtime-first bootstrap.
///
/// This assembles a ``BaseChatRuntime``, registers the built-in backends,
/// and presents the standard chat + model-management surfaces.
@main
struct MinimalExampleApp: App {
    private let runtime: BaseChatRuntime
    @State private var chatViewModel: ChatViewModel
    @State private var sessionManager: SessionManagerViewModel
    @State private var modelManagement: ModelManagementViewModel

    init() {
        let runtime = try! BaseChatRuntime(
            configuration: BaseChatConfiguration(
                appName: "Minimal Chat",
                bundleIdentifier: "com.basechatkit.minimal-example"
            )
        )
        self.runtime = runtime

        DefaultBackends.register(with: runtime.inferenceService)

        let vm = ChatViewModel(inferenceService: runtime.inferenceService)
        vm.foundationModelProvider = {
            if #available(iOS 26, macOS 26, *) {
                return FoundationBackend.isAvailable
            }
            return false
        }
        vm.configure(runtime: runtime)
        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(runtime: runtime)

        vm.refreshModels()

        let initialSession = sessionManager.sessions.first ?? (try? sessionManager.createSession())
        if let initialSession {
            sessionManager.activeSession = initialSession
            vm.switchToSession(initialSession)
            vm.dispatchSelectedLoad()
        }

        let downloadManager = BackgroundDownloadManager()
        let huggingFaceService = HuggingFaceService()

        _chatViewModel = State(initialValue: vm)
        _sessionManager = State(initialValue: sessionManager)
        _modelManagement = State(initialValue: ModelManagementViewModel(
            huggingFaceService: huggingFaceService,
            downloadManager: downloadManager
        ))
    }

    var body: some Scene {
        WindowGroup {
            MinimalContentView()
                .environment(chatViewModel)
                .environment(sessionManager)
                .environment(modelManagement)
        }
        .modelContainer(runtime.modelContainer)
    }
}
