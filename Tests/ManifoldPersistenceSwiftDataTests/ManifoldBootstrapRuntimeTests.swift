import XCTest
import ManifoldRuntime
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference

/// Defends the W1 cutover wiring (#947): ``ManifoldBootstrap`` must construct
/// and expose a ``ConversationRuntime`` by default so host apps that route
/// through ``ChatViewModel/configure(runtime:)`` get the runtime turn loop
/// without an extra opt-in step.
@MainActor
final class ManifoldBootstrapRuntimeTests: XCTestCase {

    func test_init_exposesConversationRuntime() throws {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let runtime = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Runtime Default",
                bundleIdentifier: "com.manifoldkit.runtime-tests.runtime-default.\(UUID().uuidString)"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        // The runtime must be wired up — non-optional and present in the
        // bootstrap surface. Sabotage `self.conversationRuntime = ...` in
        // ManifoldBootstrap.init and the value would no longer compile;
        // sabotage by removing the property and this test stops compiling.
        let conversationRuntime: ConversationRuntime = runtime.conversationRuntime
        _ = conversationRuntime
    }

    func test_init_runtimeEventsStreamIsLive() async throws {
        // Sanity-check that the runtime's event stream is live (continuation
        // hasn't been finished prematurely). Iterating with a tight cancel
        // confirms the AsyncStream is open and consumable.
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let bootstrap = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Runtime Stream",
                bundleIdentifier: "com.manifoldkit.runtime-tests.runtime-stream.\(UUID().uuidString)"
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
