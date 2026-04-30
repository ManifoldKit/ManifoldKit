import XCTest
import SwiftUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
@testable import BaseChatUI
@testable import BaseChatUIModelManagement

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Guards the runtime-bootstrap migration path documented in the README and
/// the MinimalExample app: assemble a `BaseChatBootstrap`, configure the chat
/// view models from it, mount `ChatView(apiConfiguration:)`, and verify that
/// runtime-driven persistence is wired without view-lifecycle late-binding.
final class RuntimeBootstrapMigrationGuardTests: XCTestCase {

    @MainActor
    func test_runtimeBootstrap_persistenceWiredBeforeFirstRender() throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let runtime = try BaseChatBootstrap(
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

        // Real architectural invariant: BaseChatBootstrap owns a single
        // SessionStore + MessageStore adapter, and both view models must
        // latch onto that exact instance when configured from the same
        // runtime. A round-trip
        // smoke check (persistence != nil) doesn't defend this — it would
        // pass even if each view model received its own independent provider,
        // which would silently break cross-view-model session visibility.
        // Sabotage check: change `configure(runtime:)` on either view model
        // to wrap `runtime.persistence` in a fresh `SwiftDataPersistenceProvider`
        // and this identity assertion fails.
        XCTAssertNotNil(chatViewModel.persistence,
            "ChatViewModel.configure(runtime:) must install the runtime's persistence provider")
        XCTAssertNotNil(sessionManager.persistence,
            "SessionManagerViewModel.configure(runtime:) must install the runtime's persistence provider")
        XCTAssertTrue((chatViewModel.persistence as AnyObject) === (sessionManager.persistence as AnyObject),
            "Both view models must share the runtime's single persistence provider instance")

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
