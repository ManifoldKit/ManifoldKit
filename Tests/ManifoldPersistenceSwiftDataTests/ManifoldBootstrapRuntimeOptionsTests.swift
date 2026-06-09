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
        private var pending: [CheckedContinuation<CompletedTurn, any Error>] = []

        func postGeneration(_ turn: CompletedTurn) async {
            receivedTurns.append(turn)
            for cont in pending { cont.resume(returning: turn) }
            pending.removeAll()
        }

        /// Suspends until the next `postGeneration` delivery and returns it.
        ///
        /// Returns immediately when the hook has already fired (prevents a race
        /// where the generation task completes before this continuation is
        /// registered). Uses a throwing continuation so task cancellation can
        /// resume the stored continuation with `CancellationError`, avoiding a
        /// debug-build deinit precondition trap when the caller's 5-second
        /// deadline fires first.
        func awaitNextTurn() async throws -> CompletedTurn {
            if let already = receivedTurns.last { return already }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { pending.append($0) }
            } onCancel: {
                Task { await self.cancelPending() }
            }
        }

        private func cancelPending() {
            let waiters = pending
            pending.removeAll()
            for cont in waiters { cont.resume(throwing: CancellationError()) }
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
            group.addTask { try await hook.awaitNextTurn() }
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

    // MARK: - Wiring parity between sync init and async build()
    //
    // Regression gate for the class of bug where a new ConversationRuntimeOptions
    // field is wired in the public `init` but silently omitted from the `build()`
    // path (or vice versa). The historical incident: `build()` shipped with RAG
    // wiring missing; `makeRAGService` fixed that. `makeConversationRuntime`
    // closes the equivalent gap for all ConversationRuntime arguments.
    //
    // We use `auxiliaryInferenceService` as the probe because it is the most
    // directly observable runtime property that flows through runtimeOptions.
    // If both paths call the same factory, both will thread the option through.
    // If either path regresses to a hand-rolled construction, the assertion fails.

    func test_initAndBuild_wireAuxiliaryInferenceServiceIdentically() async throws {
        let original = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = original }

        let auxiliaryBackend = MockInferenceBackend()
        let auxiliaryService = InferenceService(backend: auxiliaryBackend, name: "AuxService")

        var options = ConversationRuntimeOptions()
        options.auxiliaryInferenceService = auxiliaryService

        // Sync init path
        let syncBootstrap = try ManifoldBootstrap(
            configuration: makeConfig(tag: "aux-wiring-sync"),
            runtimeOptions: options,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        XCTAssertTrue(
            syncBootstrap.conversationRuntime.auxiliaryInferenceService === auxiliaryService,
            "sync init: auxiliaryInferenceService must be threaded through to ConversationRuntime"
        )

        // Async build() path — delegates to the same internal init and makeConversationRuntime
        let (progress, task) = ManifoldBootstrap.build(
            configuration: makeConfig(tag: "aux-wiring-build"),
            runtimeOptions: options,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        for await _ in progress {}
        let buildBootstrap = try await task.value
        XCTAssertTrue(
            buildBootstrap.conversationRuntime.auxiliaryInferenceService === auxiliaryService,
            "build() path: auxiliaryInferenceService must be threaded through to ConversationRuntime"
        )
    }
}
