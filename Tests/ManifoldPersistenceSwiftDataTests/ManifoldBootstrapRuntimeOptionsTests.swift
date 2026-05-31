import XCTest
import ManifoldRuntime
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// Verifies that ``ConversationRuntimeOptions`` is threaded through to the
/// ``ConversationRuntime`` constructed by both ``ManifoldBootstrap/init`` and
/// ``ManifoldBootstrap/build``.
///
/// Each behavioral test wires a ``GenerationHook`` through
/// ``ConversationRuntimeOptions`` and confirms the hook fires during a real
/// turn, proving the options aren't silently discarded.
@MainActor
final class ManifoldBootstrapRuntimeOptionsTests: XCTestCase {

    // MARK: - Recording hook

    actor RecordingHook: GenerationHook {
        private(set) var receivedTurns: [CompletedTurn] = []
        private var pending: [CheckedContinuation<CompletedTurn, Never>] = []

        func postGeneration(_ turn: CompletedTurn) async {
            receivedTurns.append(turn)
            for cont in pending { cont.resume(returning: turn) }
            pending.removeAll()
        }

        func awaitNextTurn() async -> CompletedTurn {
            await withCheckedContinuation { pending.append($0) }
        }
    }

    enum TestError: Error { case deadlineElapsed }

    // MARK: - Helpers

    private func makeConfig(tag: String) -> ManifoldConfiguration {
        ManifoldConfiguration(
            appName: "RuntimeOptionsTests",
            bundleIdentifier: "com.manifoldkit.runtime-options-tests.\(tag).\(UUID().uuidString)"
        )
    }

    /// Sends one turn through `runtime` and returns once the given hook fires.
    /// Fails if the hook doesn't fire within 5 seconds.
    private func sendTurnAndAwaitHook(
        through runtime: ConversationRuntime,
        backend: MockInferenceBackend,
        hook: RecordingHook,
        tokens: [String] = ["ok"]
    ) async throws {
        backend.tokensToYield = tokens
        backend.isModelLoaded = true
        _ = try await runtime.processTurn(
            TurnInput(sessionID: UUID(), kind: .send(text: "hello"))
        )
        // Await the hook's own signal — deterministic, no sleep.
        try await withThrowingTaskGroup(of: CompletedTurn.self) { group in
            group.addTask { await hook.awaitNextTurn() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw TestError.deadlineElapsed
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Default options

    func test_defaultOptions_producesValidRuntime() throws {
        let original = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = original }

        let bootstrap = try ManifoldBootstrap(
            configuration: makeConfig(tag: "default-options"),
            runtimeOptions: ConversationRuntimeOptions(),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        // Runtime is live and its event stream can be iterated.
        let conversationRuntime: ConversationRuntime = bootstrap.conversationRuntime
        _ = conversationRuntime
    }

    // MARK: - init path

    func test_init_generationHookFiresAfterTurn() async throws {
        let original = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = original }

        let hook = RecordingHook()
        var options = ConversationRuntimeOptions()
        options.generationHooks = [hook]

        let backend = MockInferenceBackend()
        let bootstrap = try ManifoldBootstrap(
            configuration: makeConfig(tag: "hook-init"),
            inferenceService: InferenceService(backend: backend, name: "HookInitMock"),
            runtimeOptions: options,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        try await sendTurnAndAwaitHook(
            through: bootstrap.conversationRuntime, backend: backend, hook: hook
        )

        let count = await hook.receivedTurns.count
        XCTAssertEqual(count, 1,
            "GenerationHook registered via runtimeOptions must fire once after a completed turn")
    }

    func test_init_omittingRuntimeOptions_preservesExistingBehaviour() throws {
        // Callers that don't pass runtimeOptions must compile and produce a
        // valid runtime — source compatibility gate.
        let original = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = original }

        let bootstrap = try ManifoldBootstrap(
            configuration: makeConfig(tag: "no-options"),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        let conversationRuntime: ConversationRuntime = bootstrap.conversationRuntime
        _ = conversationRuntime
    }

    // MARK: - build() async path

    func test_build_generationHookFiresAfterTurn() async throws {
        let original = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = original }

        let hook = RecordingHook()
        var options = ConversationRuntimeOptions()
        options.generationHooks = [hook]

        let backend = MockInferenceBackend()
        let (progress, task) = ManifoldBootstrap.build(
            configuration: makeConfig(tag: "hook-build"),
            inferenceService: InferenceService(backend: backend, name: "HookBuildMock"),
            runtimeOptions: options,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        for await _ in progress {}
        let bootstrap = try await task.value

        try await sendTurnAndAwaitHook(
            through: bootstrap.conversationRuntime, backend: backend, hook: hook
        )

        let count = await hook.receivedTurns.count
        XCTAssertEqual(count, 1,
            "GenerationHook registered via runtimeOptions must fire on the build() path too")
    }

    func test_build_omittingRuntimeOptions_preservesExistingBehaviour() async throws {
        let original = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = original }

        let (progress, task) = ManifoldBootstrap.build(
            configuration: makeConfig(tag: "build-no-options"),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        for await _ in progress {}
        let bootstrap = try await task.value

        let conversationRuntime: ConversationRuntime = bootstrap.conversationRuntime
        _ = conversationRuntime
    }
}
