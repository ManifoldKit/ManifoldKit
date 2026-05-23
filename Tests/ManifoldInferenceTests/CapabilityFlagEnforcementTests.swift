import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests that `GenerationQueue.enqueue()` enforces capability flags.
///
/// Coverage:
/// - tools rejected (throw + warning) when backend reports `supportsToolCalling == false`
/// - warning hook fires before the throw
/// - empty-tools request succeeds on a non-tool-calling backend (no regression)
/// - tools allowed when `supportsToolCalling == true`
///
/// The guard lives at the top of `enqueue(structuredMessages:...)`, immediately
/// after the queue-depth check, so the throw is synchronous and happens before
/// the request enters the queue.
@MainActor
final class CapabilityFlagEnforcementTests: XCTestCase {

    // MARK: - Thread-safe warning collector

    /// Thread-safe collector for warning hook invocations. The hook is
    /// `@Sendable` so captured state must be protected against concurrent
    /// writes even though, in practice, the coordinator fires the hook on
    /// the same `@MainActor` isolation as `enqueue()`.
    private final class WarningCollector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var entries: [(backendType: String, message: String)] = []

        func record(backendType: String, message: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.append((backendType: backendType, message: message))
        }
    }

    // MARK: - Fixtures

    private var provider: FakeGenerationContextProvider!

    override func setUp() async throws {
        try await super.setUp()
        provider = FakeGenerationContextProvider()
    }

    override func tearDown() async throws {
        // Always clear the warning hook to avoid cross-test leakage.
        GenerationQueue.toolsUnsupportedWarningHook = nil
        provider = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeCoordinator() -> GenerationQueue {
        let coordinator = GenerationQueue()
        provider.bind(to: coordinator)
        return coordinator
    }

    private func makeNonToolCapableBackend() -> MockInferenceBackend {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false
        )
        let backend = MockInferenceBackend(capabilities: caps)
        backend.isModelLoaded = true
        return backend
    }

    private func makeNoopTool() -> ToolDefinition {
        ToolDefinition(name: "noop", description: "test tool", parameters: .object([:]))
    }

    // MARK: - Tests

    /// Passing a non-empty `tools` array to `enqueue()` when the active
    /// backend reports `supportsToolCalling == false` must:
    /// 1. Fire `toolsUnsupportedWarningHook` exactly once.
    /// 2. Throw `InferenceError.inferenceFailure` synchronously before any
    ///    stream is returned — tools must never silently no-op.
    ///
    /// Sabotage: if you comment out the `throw` at the end of the capability
    /// guard in `GenerationQueue.enqueue(structuredMessages:...)`, this
    /// test fails because `enqueue` returns a stream instead of throwing.
    func test_tools_rejectedOnNonToolCallingBackend() throws {
        let backend = makeNonToolCapableBackend()
        provider = FakeGenerationContextProvider(backend: backend)
        let coordinator = makeCoordinator()

        let collector = WarningCollector()
        GenerationQueue.toolsUnsupportedWarningHook = { backendType, message in
            collector.record(backendType: backendType, message: message)
        }

        let tool = makeNoopTool()

        XCTAssertThrowsError(
            try coordinator.enqueue(
                messages: [("user", "do something")],
                tools: [tool]
            )
        ) { error in
            guard case InferenceError.inferenceFailure(let msg) = error else {
                XCTFail("Expected InferenceError.inferenceFailure, got \(error)")
                return
            }
            XCTAssertTrue(
                msg.contains("does not support tool calling"),
                "Error message must describe the capability gap: \(msg)"
            )
        }

        // The warning hook must have fired before the throw so the caller
        // has a log trail even if they don't inspect the error message.
        XCTAssertEqual(collector.entries.count, 1,
                       "toolsUnsupportedWarningHook must fire exactly once")
        XCTAssertEqual(collector.entries.first?.backendType, "MockInferenceBackend")
    }

    /// Passing `tools: []` (or not passing tools at all) to a non-tool-calling
    /// backend must succeed — the capability guard only fires when tools are
    /// actually provided.
    func test_emptyTools_onNonToolCallingBackend_succeeds() async throws {
        let backend = makeNonToolCapableBackend()
        provider = FakeGenerationContextProvider(backend: backend)
        let coordinator = makeCoordinator()

        // No tools → enqueue must succeed and the stream must complete normally.
        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "hello")],
            tools: []
        )

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { tokens.append(t) }
        }

        XCTAssertFalse(tokens.isEmpty,
                       "Generation should produce tokens when no tools are passed")
    }

    /// Passing tools to a backend that DOES support tool calling must not
    /// throw — the guard must only block the incapable-backend path.
    func test_tools_allowedOnToolCapableBackend() throws {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true
        )
        let backend = MockInferenceBackend(capabilities: caps)
        backend.isModelLoaded = true
        provider = FakeGenerationContextProvider(backend: backend)
        let coordinator = makeCoordinator()

        let tool = makeNoopTool()

        // Must not throw; a valid stream token is returned.
        let (_, _) = try coordinator.enqueue(
            messages: [("user", "call the tool")],
            tools: [tool]
        )
    }
}
