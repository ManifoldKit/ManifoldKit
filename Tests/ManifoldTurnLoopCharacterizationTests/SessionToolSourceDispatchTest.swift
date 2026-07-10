import XCTest
@testable import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

// MARK: - StubGenerateImageToolSource

/// Minimal ``SessionToolSource`` that both *advertises* a `generate_image`
/// tool and *resolves* it to a fixed result.
///
/// Stands in for the production ``ImageGenerationToolSource`` /
/// `VideoGenerationToolSource` / `WebSearchToolSource` without dragging in
/// `ManifoldUI`'s `ChatViewModel`. The only behaviour under test is that an
/// advertised session tool reaches `resolve` — the body just proves the call
/// arrived and carried the model's arguments through.
private struct StubGenerateImageToolSource: SessionToolSource {
    static let toolName = "generate_image"
    static let successContent = "image-generated"

    func toolDefinitions(for session: ManifoldInference.ChatSession) async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: Self.toolName,
                description: "Generate an image from a text prompt.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "prompt": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("prompt")])
                ])
            )
        ]
    }

    func resolve(
        toolName: String,
        arguments: String,
        session: ManifoldInference.ChatSession
    ) async throws -> ToolResult {
        guard toolName == Self.toolName else {
            return ToolResult(callId: toolName, content: "unexpected tool", errorKind: .unknownTool)
        }
        // Echo the round-tripped arguments back so the test can confirm the
        // model's JSON survived the JSONSchemaValue → string re-encode.
        return ToolResult(callId: toolName, content: "\(Self.successContent):\(arguments)")
    }
}

// MARK: - SessionToolSourceDispatchTest

/// Tripwire for #1606: an advertised ``SessionToolSource`` tool must actually
/// dispatch to its `resolve` when the model calls it, instead of falling
/// through ``ToolRegistry`` as ``ToolResult/ErrorKind/unknownTool``.
///
/// Integration test — it drives the real ``ConversationRuntime`` turn loop
/// against ``MockInferenceBackend`` and an in-memory SwiftData store.
@MainActor
final class SessionToolSourceDispatchTest: XCTestCase {

    private static func toolCapableBackend() -> MockInferenceBackend {
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        ))
        backend.isModelLoaded = true
        return backend
    }

    /// A model tool call for a session-source-advertised tool dispatches and
    /// returns a real result. Before the #1606 fix this came back as
    /// `unknownTool` because nothing registered the source's `resolve` into the
    /// ``ToolRegistry`` — reverting the fix makes the `unknownTool` assertion
    /// below fail, which is the falsifiability the tripwire exists for.
    func test_advertisedSessionTool_dispatchesToResolve_notUnknownTool() async throws {
        let stack = try InMemoryPersistenceHarness.make()
        let session = ManifoldInference.ChatSession(id: UUID(), title: "dispatch")
        try await stack.provider.insertSession(session)

        let backend = Self.toolCapableBackend()
        // Turn 1: emit the tool call only. Turn 2: final answer after the
        // tool result is fed back to the model.
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "img-1", toolName: StubGenerateImageToolSource.toolName, arguments: "{\"prompt\":\"a cat\"}")]
        ]
        backend.tokensToYieldPerTurn = [[], ["Done"]]

        // Empty registry — there is NO host-installed executor for
        // `generate_image`. The only way the call resolves is through the
        // per-turn SessionToolSource → ToolExecutor bridge.
        let registry = ToolRegistry()
        let service = InferenceService(backend: backend, name: "DispatchMock", toolRegistry: registry)
        let runtime = ConversationRuntime(
            messageStore: stack.provider,
            sessionStore: stack.provider,
            inferenceService: service
        )
        await runtime.updateSessionToolSources([StubGenerateImageToolSource()])

        let handle = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: session.id, kind: .send(text: "make me an image"))
        )
        _ = await handle?.outcome

        // The assistant turn persists the dispatched tool result as a
        // `.toolResult` content part.
        let records = try await stack.provider.fetchMessages(for: session.id)
        let toolResults: [ToolResult] = records
            .flatMap(\.contentParts)
            .compactMap { part in
                if case .toolResult(let result) = part { return result }
                return nil
            }

        guard let result = toolResults.first(where: { $0.callId == "img-1" }) else {
            XCTFail("expected a dispatched tool result for the generate_image call; got \(toolResults)")
            return
        }
        XCTAssertNotEqual(
            result.errorKind,
            .unknownTool,
            "advertised session tool must dispatch to resolve, not fall through ToolRegistry as unknownTool"
        )
        XCTAssertTrue(
            result.content.hasPrefix(StubGenerateImageToolSource.successContent),
            "tool result content should come from the source's resolve, got: \(result.content)"
        )
        XCTAssertTrue(
            result.content.contains("a cat"),
            "the model's JSON arguments should survive the round-trip to resolve, got: \(result.content)"
        )
    }

    /// The per-turn session executor must not leak into the shared registry:
    /// once the turn ends, `generate_image` is gone again so the next turn
    /// re-binds it to a fresh ``ManifoldInference.ChatSession`` rather than reusing a stale
    /// one.
    func test_sessionToolExecutor_unregisteredAfterTurn() async throws {
        let stack = try InMemoryPersistenceHarness.make()
        let session = ManifoldInference.ChatSession(id: UUID(), title: "leak-check")
        try await stack.provider.insertSession(session)

        let backend = Self.toolCapableBackend()
        backend.tokensToYieldPerTurn = [["Hi"]]  // plain turn, no tool call

        let registry = ToolRegistry()
        let service = InferenceService(backend: backend, name: "DispatchMock", toolRegistry: registry)
        // sessionStore: nil so touchSession() is a no-op — this test only cares
        // about the tool registry and must not race SwiftData against stack deallocation.
        let runtime = ConversationRuntime(
            messageStore: stack.provider,
            sessionStore: nil,
            inferenceService: service
        )
        await runtime.updateSessionToolSources([StubGenerateImageToolSource()])

        let handle = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: session.id, kind: .send(text: "hello"))
        )
        _ = await handle?.outcome

        let leaked = service.toolRegistry?.contains(name: StubGenerateImageToolSource.toolName) ?? false
        XCTAssertFalse(
            leaked,
            "session-scoped executor must be unregistered when the turn ends; a leak would bind later turns to a stale session"
        )
    }

    /// Register-then-enqueue-fails (#1725 step C): when `enqueueAsync` throws
    /// AFTER the session tool executors were registered (#1606 ordering puts
    /// registration strictly before enqueue), the error-path unregister in
    /// the turn loop must still run — otherwise the failed turn leaks a
    /// session-scoped executor into the shared registry.
    ///
    /// The failure is driven by ``MockInferenceBackend/rejectToolCarryingEnqueues``:
    /// the queue's capability gate reads `backend.capabilities` at enqueue
    /// time and rejects tool-carrying requests synchronously, before any
    /// stream exists — so no stream-drain cleanup path can mask a missing
    /// enqueue-failure unregister.
    func test_sessionToolExecutor_unregisteredWhenEnqueueThrows() async throws {
        let stack = try InMemoryPersistenceHarness.make()
        let session = ManifoldInference.ChatSession(id: UUID(), title: "enqueue-fail")
        try await stack.provider.insertSession(session)

        let backend = Self.toolCapableBackend()
        backend.rejectToolCarryingEnqueues = true

        let registry = ToolRegistry()
        let service = InferenceService(backend: backend, name: "DispatchMock", toolRegistry: registry)
        // sessionStore wired so the executor fetches a real session record —
        // registration only happens with a non-nil record, and the unregister
        // assertion below would be vacuous without it.
        let runtime = ConversationRuntime(
            messageStore: stack.provider,
            sessionStore: stack.provider,
            inferenceService: service
        )
        await runtime.updateSessionToolSources([StubGenerateImageToolSource()])

        let handle = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: session.id, kind: .send(text: "should fail at enqueue"))
        )
        let outcome = await handle?.outcome

        // The turn must have failed at enqueue (capability gate), proving the
        // failure happened on the enqueue path — i.e. after register, before
        // any stream existed — rather than the turn quietly succeeding.
        guard case .inference = outcome?.error else {
            XCTFail("expected an enqueue-time inference failure, got \(String(describing: outcome?.error))")
            return
        }

        let leaked = service.toolRegistry?.contains(name: StubGenerateImageToolSource.toolName) ?? false
        XCTAssertFalse(
            leaked,
            "enqueue failure must still unregister the session tool executors registered before enqueueAsync (#1606 error path)"
        )
    }
}
