@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Verifies that ``ConversationTurnExecutor`` honours the
/// ``BackendCapabilities/maxAdvertisedToolCount`` cap when building the
/// ``GenerationConfig/tools`` list for each turn.
///
/// The cap exists for backends like `FoundationBackend` that degrade when the
/// tool catalogue exceeds a small number of entries. When set, the executor
/// must truncate the advertised tool list to at most `cap` entries before
/// enqueuing the generation request.
@MainActor
final class FoundationBackendToolCapTests: XCTestCase {

    // MARK: - Helpers

    private func makeCapBackend(cap: Int) -> MockInferenceBackend {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        // Mirror the FoundationBackend capability set, but with a configurable cap
        // so this test does not require a real Apple Intelligence entitlement.
        backend.capabilities = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            maxAdvertisedToolCount: cap
        )
        return backend
    }

    private func makeRuntime(
        backend: MockInferenceBackend,
        registry: ToolRegistry
    ) -> ConversationRuntime {
        let inference = InferenceService(backend: backend, name: "Mock", toolRegistry: registry)
        let store = CapTestMessageStore()
        return ConversationRuntime(messageStore: store, inferenceService: inference)
    }

    private func makeToolRegistry(count: Int) -> ToolRegistry {
        let registry = ToolRegistry()
        for index in 0..<count {
            let name = String(format: "tool_%02d", index)
            registry.register(StubToolExecutor(name: name))
        }
        return registry
    }

    private func collectUntilStreamFinished(
        from runtime: ConversationRuntime
    ) async throws -> [ConversationEvent] {
        var events: [ConversationEvent] = []
        let task = Task {
            for await event in runtime.events {
                events.append(event)
                if case .streamFinished = event { break }
                if case .errorRaised = event { break }
            }
            return events
        }
        return try await withThrowingTaskGroup(of: [ConversationEvent].self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                task.cancel()
                throw CancellationError()
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? []
        }
    }

    // MARK: - Tests

    /// When the backend advertises a cap smaller than the number of registered
    /// tools, the generation request must receive at most `cap` tools.
    func test_toolCapIsEnforced_whenBackendHasMaxAdvertisedToolCount() async throws {
        let cap = 3
        let totalTools = 20
        let backend = makeCapBackend(cap: cap)
        let registry = makeToolRegistry(count: totalTools)
        let runtime = makeRuntime(backend: backend, registry: registry)

        let handle = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "use any tool")
        ))

        let events = try await collectUntilStreamFinished(from: runtime)
        _ = events  // events consumed; we care about the backend's received config

        let config = try XCTUnwrap(backend.lastConfig,
            "backend.lastConfig must be set after a generation turn")

        XCTAssertLessThanOrEqual(config.tools.count, cap,
            "backend must not receive more than \(cap) tools (maxAdvertisedToolCount)")
        XCTAssertEqual(config.tools.count, cap,
            "backend should receive exactly \(cap) tools when more are registered")

        // Sabotage check: removing the cap enforcement in SessionToolDispatchBinder.advertisedToolDefinitions
        // would cause config.tools.count == 20, failing the assertion above.
        _ = handle
    }

    /// When the backend has no tool cap (`maxAdvertisedToolCount == nil`), all
    /// registered tools are forwarded unchanged.
    func test_allToolsForwarded_whenNoCapIsSet() async throws {
        let totalTools = 8
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.capabilities = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true
            // maxAdvertisedToolCount intentionally omitted (defaults to nil)
        )
        let registry = makeToolRegistry(count: totalTools)
        let runtime = makeRuntime(backend: backend, registry: registry)

        let handle = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "use any tool")
        ))

        let events = try await collectUntilStreamFinished(from: runtime)
        _ = events

        let config = try XCTUnwrap(backend.lastConfig)
        XCTAssertEqual(config.tools.count, totalTools,
            "all \(totalTools) tools must be forwarded when no cap is set")

        _ = handle
    }

    /// When the registered tool count is already at or below the cap, the full
    /// list is forwarded without truncation.
    func test_toolsNotTruncated_whenCountBelowCap() async throws {
        let cap = 16
        let totalTools = 5
        let backend = makeCapBackend(cap: cap)
        let registry = makeToolRegistry(count: totalTools)
        let runtime = makeRuntime(backend: backend, registry: registry)

        let handle = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "use any tool")
        ))

        let events = try await collectUntilStreamFinished(from: runtime)
        _ = events

        let config = try XCTUnwrap(backend.lastConfig)
        XCTAssertEqual(config.tools.count, totalTools,
            "tool list must not be truncated when count (\(totalTools)) is below cap (\(cap))")

        _ = handle
    }

    /// The truncated list uses the same alphabetic ordering as
    /// ``ToolRegistry/advertisedDefinitions``, so the first `cap` entries are
    /// always deterministic regardless of registration order.
    func test_truncatedToolsAreAlphabeticallyFirst() async throws {
        let cap = 2
        let backend = makeCapBackend(cap: cap)
        let registry = ToolRegistry()
        // Register in reverse-alpha order to confirm ordering is applied first.
        registry.register(StubToolExecutor(name: "zebra"))
        registry.register(StubToolExecutor(name: "mango"))
        registry.register(StubToolExecutor(name: "apple"))
        registry.register(StubToolExecutor(name: "banana"))
        let runtime = makeRuntime(backend: backend, registry: registry)

        let handle = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "use any tool")
        ))

        let events = try await collectUntilStreamFinished(from: runtime)
        _ = events

        let config = try XCTUnwrap(backend.lastConfig)
        XCTAssertEqual(config.tools.map(\.name), ["apple", "banana"],
            "truncated list must contain the lexicographically-first \(cap) tools")

        _ = handle
    }
}

// MARK: - Minimal ToolExecutor stub

/// Registers as a tool executor with no-op dispatch. Used to populate a
/// ToolRegistry in tests without requiring a full MCP server setup.
private struct StubToolExecutor: ToolExecutor, Sendable {
    let definition: ToolDefinition

    init(name: String) {
        self.definition = ToolDefinition(
            name: name,
            description: "Stub tool \(name)",
            parameters: .object(["type": .string("object")])
        )
    }

    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        ToolResult(callId: "", content: "ok")
    }
}

// MARK: - Minimal in-memory MessageStore for this test file

private final class CapTestMessageStore: MessageStore, @unchecked Sendable {
    private var messages: [UUID: ChatMessage] = [:]

    func insertMessage(_ message: ChatMessage) async throws {
        messages[message.id] = message
    }

    func updateMessage(_ message: ChatMessage) async throws {
        messages[message.id] = message
    }

    func deleteMessage(_ messageID: UUID) async throws {
        messages.removeValue(forKey: messageID)
    }

    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
        messages.values.filter { $0.sessionID == sessionID }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func deleteMessages(for sessionID: UUID) async throws {
        messages = messages.filter { $0.value.sessionID != sessionID }
    }
}
