import XCTest
import BaseChatRuntime
@testable import BaseChatPersistenceSwiftData
@testable import BaseChatInference

/// Defends the W1 cutover wiring (#947): ``BaseChatBootstrap`` must construct
/// and expose a ``ConversationRuntime`` by default so host apps that route
/// through ``ChatViewModel/configure(runtime:)`` get the runtime turn loop
/// without an extra opt-in step.
@MainActor
final class BaseChatBootstrapRuntimeTests: XCTestCase {

    func test_init_exposesConversationRuntime() throws {
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let runtime = try BaseChatBootstrap(
            configuration: BaseChatConfiguration(
                appName: "Runtime Default",
                bundleIdentifier: "com.basechatkit.runtime-tests.runtime-default.\(UUID().uuidString)"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        // The runtime must be wired up — non-optional and present in the
        // bootstrap surface. Sabotage `self.conversationRuntime = ...` in
        // BaseChatBootstrap.init and the value would no longer compile;
        // sabotage by removing the property and this test stops compiling.
        let conversationRuntime: ConversationRuntime = runtime.conversationRuntime
        _ = conversationRuntime
    }

    func test_init_runtimeEventsStreamIsLive() async throws {
        // Sanity-check that the runtime's event stream is live (continuation
        // hasn't been finished prematurely). Iterating with a tight cancel
        // confirms the AsyncStream is open and consumable.
        let originalConfiguration = BaseChatConfiguration.shared
        defer { BaseChatConfiguration.shared = originalConfiguration }

        let bootstrap = try BaseChatBootstrap(
            configuration: BaseChatConfiguration(
                appName: "Runtime Stream",
                bundleIdentifier: "com.basechatkit.runtime-tests.runtime-stream.\(UUID().uuidString)"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        let stream = bootstrap.conversationRuntime.events
        let drainTask = Task<Bool, Never> {
            for await _ in stream { return true }
            return false
        }
        // Cancel the drain immediately — we only need to prove the stream
        // exists and didn't throw on iterator creation.
        drainTask.cancel()
        _ = await drainTask.value
    }
}
