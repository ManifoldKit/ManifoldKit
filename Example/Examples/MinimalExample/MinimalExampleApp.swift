import SwiftUI
import SwiftData
import BaseChatCore
import BaseChatUI
import BaseChatBackends

/// The simplest possible BaseChatKit app — under 40 lines.
///
/// This assembles a ``BaseChatRuntime``, registers all built-in backends,
/// and presents the standard ChatView. No model curation, no custom UI.
@main
struct MinimalExampleApp: App {
    private let runtime: BaseChatRuntime
    @State private var chatViewModel: ChatViewModel
    @State private var sessionManager: SessionManagerViewModel

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
        _chatViewModel = State(initialValue: vm)

        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(runtime: runtime)
        _sessionManager = State(initialValue: sessionManager)
    }

    var body: some Scene {
        WindowGroup {
            MinimalContentView()
                .environment(chatViewModel)
                .environment(sessionManager)
        }
        .modelContainer(runtime.modelContainer)
    }
}
