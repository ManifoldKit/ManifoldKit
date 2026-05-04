import XCTest
import BaseChatRuntime
@testable import BaseChatUI
@testable import BaseChatPersistenceSwiftData
@testable import BaseChatInference

/// Defends the `ChatViewModel.configure(_:)` convenience method that wires both
/// runtimes into a view model in a single call (PR 9 / umbrella #1002).
///
/// Tests 3 and 4 from the BootstrapImageWiring spec live here because
/// `BaseChatPersistenceSwiftDataTests` cannot import `BaseChatUI` (no `ChatViewModel`).
@MainActor
final class BootstrapConfigureImageWiringTests: XCTestCase {

    // MARK: - Helpers

    private func makeBootstrap(
        imageGenerationService: ImageGenerationService? = nil
    ) throws -> BaseChatBootstrap {
        let originalConfiguration = BaseChatConfiguration.shared
        addTeardownBlock { BaseChatConfiguration.shared = originalConfiguration }

        return try BaseChatBootstrap(
            configuration: BaseChatConfiguration(
                appName: "Bootstrap Configure Image Wiring Tests",
                bundleIdentifier: "com.basechatkit.tests.bootstrap-configure-image-wiring.\(UUID().uuidString)"
            ),
            imageGenerationService: imageGenerationService,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
    }

    // MARK: - Test 3: configure(_:) wires imageRuntime into ChatViewModel when opted in

    func test_configure_wiresImageRuntimeIntoViewModel_whenOptedIn() throws {
        let service = ImageGenerationService()
        let bootstrap = try makeBootstrap(imageGenerationService: service)

        let chatViewModel = ChatViewModel(
            inferenceService: bootstrap.inferenceService,
            conversationRuntime: bootstrap.conversationRuntime
        )

        // Before configure — imageRuntime should be nil (no runtime installed yet).
        XCTAssertNil(
            chatViewModel.imageRuntime,
            "chatViewModel.imageRuntime must be nil before configure(_:) is called"
        )

        chatViewModel.configure(bootstrap)

        // After configure — imageRuntime must be the bootstrap's runtime instance.
        // Sabotage: remove `if let imageRuntime = bootstrap.imageRuntime { configure(imageRuntime: imageRuntime) }`
        // from RuntimeConfiguration.configure(_:) and this assertion fails.
        XCTAssertNotNil(
            chatViewModel.imageRuntime,
            "chatViewModel.imageRuntime must be non-nil after configure(_:) when bootstrap has an imageRuntime"
        )
        XCTAssertTrue(
            chatViewModel.imageRuntime === bootstrap.imageRuntime,
            "chatViewModel.imageRuntime must be the exact ImageGenerationRuntime the bootstrap created"
        )
    }

    // MARK: - Test 4: configure(_:) without image service leaves chatViewModel.imageRuntime nil

    func test_configure_doesNotWireImageRuntime_whenNotOptedIn() throws {
        // A bootstrap constructed without imageGenerationService must not
        // alter the view model's imageRuntime when configure(_:) is called.
        let bootstrap = try makeBootstrap()

        let chatViewModel = ChatViewModel(
            inferenceService: bootstrap.inferenceService,
            conversationRuntime: bootstrap.conversationRuntime
        )

        chatViewModel.configure(bootstrap)

        XCTAssertNil(
            chatViewModel.imageRuntime,
            "chatViewModel.imageRuntime must remain nil when the bootstrap was not configured with an imageGenerationService"
        )
    }
}
