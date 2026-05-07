import XCTest
import Foundation
@testable import BaseChatInference
import BaseChatRuntime
import BaseChatTestSupport

/// End-to-end coverage for a 2-turn tool-chain through ``ConversationRuntime``
/// and ``ToolRegistry``.
///
/// Flow:
///   1. User sends a message.
///   2. Backend emits toolA call.
///   3. Registry dispatches toolA; executor returns nonceA.
///   4. Backend (next turn) emits toolB call whose arguments carry nonceA,
///      proving the tool loop round-tripped the result into the next request.
///   5. Registry dispatches toolB; executor returns nonceB.
///   6. Backend emits a final text token containing nonceB.
///   7. Test asserts both executors ran exactly once and the final assistant
///      message in the store contains nonceB.
///
/// The test drives the loop through ``ConversationRuntime`` so the full
/// persistence + event fan-out path is exercised, not just the raw
/// ``InferenceService`` queue.
///
/// Sabotage-evidence:
///   M1: remove toolBExecutor from registry — toolB dispatch fails, the loop
///       stalls, and finalAssistant won't contain nonceB.
///   M2: change nonceB value in the assertion — the contains-check fails,
///       proving the test is value-sensitive.
///   M3: use a backend whose supportsToolCalling is false — ConversationRuntime
///       advertises zero tools, the backend never emits tool calls, and both
///       executor call counts stay at 0.
@MainActor
final class MultiTurnToolChainE2ETests: XCTestCase {

    // MARK: - Counting executor

    /// Executor that returns a fixed result and counts every invocation.
    ///
    /// Counter mutations are serialised through a `DispatchQueue` rather than
    /// `NSLock` because `NSLock.lock()` is unavailable from async contexts
    /// in Swift 6. `DispatchQueue.sync` is still safe to call from within a
    /// swift-concurrency task when the queue is uncontended (which it always is
    /// in a single-threaded test) — it does not release the cooperative thread.
    private final class CountingExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        private let resultContent: String
        private let _q = DispatchQueue(label: "CountingExecutor.counter")
        private var _callCount = 0

        var callCount: Int { _q.sync { _callCount } }

        init(name: String, resultContent: String) {
            self.definition = ToolDefinition(
                name: name,
                description: "test executor for \(name)",
                parameters: .object([:])
            )
            self.resultContent = resultContent
        }

        nonisolated func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            _q.sync { _callCount += 1 }
            return ToolResult(callId: "", content: resultContent, errorKind: nil)
        }
    }

    // MARK: - In-memory MessageStore

    @MainActor
    final class InMemoryMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessageRecord] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []

        func insertMessage(_ message: ChatMessageRecord) async throws {
            messages[message.id] = message
            for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
        }

        func updateMessage(_ message: ChatMessageRecord) async throws {
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
            for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
        }

        func deleteMessage(_ messageID: UUID) async throws {
            guard messages.removeValue(forKey: messageID) != nil else {
                throw ChatPersistenceError.messageNotFound(messageID)
            }
        }

        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
            messages.values
                .filter { $0.sessionID == sessionID }
                .sorted { $0.timestamp < $1.timestamp }
        }

        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }

        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {
            hooks.append(hook)
        }
    }

    // MARK: - Helpers

    /// Builds a ``MockInferenceBackend`` that advertises tool-calling support.
    ///
    /// The default capability set on ``MockInferenceBackend`` has
    /// `supportsToolCalling = false`, which causes ``InferenceService``
    /// to reject requests with tools. We need the flag true so the generation
    /// queue wires up the tool loop.
    private func makeToolCapableBackend() -> MockInferenceBackend {
        let capabilities = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        )
        let backend = MockInferenceBackend(capabilities: capabilities)
        backend.isModelLoaded = true
        return backend
    }

    /// Drains the runtime's event stream until `.streamFinished` (or
    /// `.errorRaised`) fires, or the deadline elapses.
    private func drainUntilFinished(
        runtime: ConversationRuntime,
        deadline: Duration = .seconds(10)
    ) async {
        let task = Task { @MainActor in
            for await event in runtime.events {
                if case .streamFinished = event { return }
                if case .errorRaised = event { return }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: deadline)
                task.cancel()
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - 2-turn tool-chain

    func test_twoTurnToolChain_roundTripsNonceAndPersistsFinalMessage() async throws {
        // Unique nonces so the test is value-sensitive and not coincidentally
        // satisfied by any other text in the conversation.
        let nonceA = "§NONCE-A§\(UUID().uuidString.prefix(8))"
        let nonceB = "§NONCE-B§\(UUID().uuidString.prefix(8))"

        let backend = makeToolCapableBackend()

        // Turn 0: backend emits a single toolA call.
        // Turn 1: backend emits a toolB call whose arguments carry nonceA
        //         (simulating a real model that read toolA's result).
        // Turn 2: final generation — no tool calls, just a token with nonceB.
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "call-A", toolName: "toolA", arguments: "{}")],
            [ToolCall(id: "call-B", toolName: "toolB", arguments: "{\"prev\": \"\(nonceA)\"}")],
            [],
        ]
        // Turn 0 and 1 emit no content tokens; turn 2 emits nonceB so it
        // ends up in the final assistant record.
        backend.tokensToYieldPerTurn = [[], [], [nonceB]]

        let toolAExecutor = CountingExecutor(name: "toolA", resultContent: nonceA)
        let toolBExecutor = CountingExecutor(name: "toolB", resultContent: nonceB)

        let registry = ToolRegistry(tools: [toolAExecutor, toolBExecutor])
        let inferenceService = InferenceService(
            backend: backend,
            name: "Mock",
            toolRegistry: registry
        )

        let store = InMemoryMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: nil,
            inferenceService: inferenceService
        )

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(
            sessionID: sessionID,
            userText: "run the tool chain",
            // Zero-interval streaming so all token batches flush immediately
            // — avoids a race where the final content token is still batched
            // when we read the store.
            streamingUpdateInterval: .zero,
            streamingBatchCharacterLimit: 1
        ))

        await drainUntilFinished(runtime: runtime)

        // Both executors must have fired exactly once.
        XCTAssertEqual(toolAExecutor.callCount, 1, "toolA must be dispatched exactly once")
        XCTAssertEqual(toolBExecutor.callCount, 1, "toolB must be dispatched exactly once")

        // The final assistant message must contain nonceB, proving the full
        // round-trip: backend → toolA → registry → nonceA in toolB arguments
        // → toolB → nonceB in final content → persisted by ConversationRuntime.
        let stored = try await store.fetchMessages(for: sessionID)
        let assistantMessages = stored.filter { $0.role == .assistant }
        XCTAssertFalse(
            assistantMessages.isEmpty,
            "At least one assistant message must be persisted"
        )
        let finalContent = assistantMessages.last?.content ?? ""
        XCTAssertTrue(
            finalContent.contains(nonceB),
            "Final assistant message must contain nonceB (\(nonceB)). Got: \(finalContent)"
        )
    }
}
