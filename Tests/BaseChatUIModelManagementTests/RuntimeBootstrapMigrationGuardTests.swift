import XCTest
import SwiftUI
@testable import BaseChatCore
@testable import BaseChatInference
@testable import BaseChatUI
@testable import BaseChatUIModelManagement

/// Compile-time guard for the README / MinimalExample runtime bootstrap path.
///
/// Host apps should be able to assemble `BaseChatRuntime`, configure the chat
/// view models from it, and render `ChatView(apiConfiguration:)` without
/// falling back to view-lifecycle persistence wiring.
final class RuntimeBootstrapMigrationGuardTests: XCTestCase {

    @MainActor
    func test_runtimeBootstrap_chatViewCompositionCompiles() throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let runtime = try BaseChatRuntime(
            configuration: BaseChatConfiguration(
                appName: "Runtime Bootstrap Guard",
                bundleIdentifier: "com.basechatkit.runtime-bootstrap-guard"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        let chatViewModel = ChatViewModel(inferenceService: runtime.inferenceService)
        let sessionManager = SessionManagerViewModel()
        chatViewModel.configure(runtime: runtime)
        sessionManager.configure(runtime: runtime)

        let view = AnyView(
            ChatView(
                showModelManagement: .constant(false),
                apiConfiguration: { APIConfigurationView() }
            )
            .environment(chatViewModel)
            .environment(sessionManager)
        )

        XCTAssertNotNil(view)
    }
}
