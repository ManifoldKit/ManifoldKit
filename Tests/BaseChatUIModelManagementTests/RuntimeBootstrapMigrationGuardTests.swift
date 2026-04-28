import XCTest
import SwiftUI
@testable import BaseChatCore
@testable import BaseChatInference
@testable import BaseChatUI
@testable import BaseChatUIModelManagement

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Guards the runtime-bootstrap migration path documented in the README and
/// the MinimalExample app: assemble a `BaseChatRuntime`, configure the chat
/// view models from it, mount `ChatView(apiConfiguration:)`, and verify that
/// runtime-driven persistence is wired without view-lifecycle late-binding.
final class RuntimeBootstrapMigrationGuardTests: XCTestCase {

    @MainActor
    func test_runtimeBootstrap_persistenceWiredBeforeFirstRender() throws {
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

        // Real piece of state: configure(runtime:) must wire persistence onto
        // the view model. Sabotage check: zero-out the call inside
        // `ChatViewModel.configure(runtime:)` and this assertion will fail.
        XCTAssertNotNil(chatViewModel.persistence,
            "configure(runtime:) must install the runtime's persistence provider")

        let view = ChatView(
            showModelManagement: .constant(false),
            apiConfiguration: { APIConfigurationView() }
        )
        .environment(chatViewModel)
        .environment(sessionManager)

        #if canImport(AppKit)
        let controller = NSHostingController(rootView: view)
        _ = controller.view
        controller.view.layoutSubtreeIfNeeded()
        #elseif canImport(UIKit)
        let controller = UIHostingController(rootView: view)
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        #endif

        // After mount, persistence is still wired — i.e. the view didn't
        // overwrite or clear it during onAppear.
        XCTAssertNotNil(chatViewModel.persistence,
            "ChatView mount must not clobber the runtime-installed persistence")
    }
}
