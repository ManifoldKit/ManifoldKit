import XCTest
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

@MainActor
final class ConsumerRuntimeHarnessTests: XCTestCase {
    private var harness: ConsumerRuntimeHarness?

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    func test_sendStreamPersist_roundTripsThroughRuntimeBootstrap() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Hello", " from", " runtime"]

        harness = try ConsumerRuntimeHarness(
            inferenceService: InferenceService(backend: backend, name: "RuntimeMock")
        )

        let session = try await harness!.createAndActivateSession(title: "Runtime Session")
        harness!.chatViewModel.inputText = "What shipped in v1?"

        await harness!.chatViewModel.sendMessage()

        XCTAssertEqual(
            harness!.chatViewModel.messages.map(\.content),
            ["What shipped in v1?", "Hello from runtime"]
        )
        let persistedContents = try await harness!.persistedMessages(for: session).map(\.content)
        XCTAssertEqual(
            persistedContents,
            ["What shipped in v1?", "Hello from runtime"]
        )
        let persistedSessionIDs = try await harness!.persistedSessions().map(\.id)
        XCTAssertEqual(persistedSessionIDs, [session.id])
    }

    func test_stopGeneration_persistsPartialAssistantReply() async throws {
        let backend = SlowMockBackend(tokenCount: 20, delayMilliseconds: 50)
        backend.tokensToYield = (0..<20).map { "tok\($0) " }

        harness = try ConsumerRuntimeHarness(
            inferenceService: InferenceService(backend: backend, name: "RuntimeSlowMock")
        )

        let session = try await harness!.createAndActivateSession(title: "Cancellation Session")
        harness!.chatViewModel.inputText = "Tell me a story"
        let sendTask = Task { @MainActor in
            await self.harness?.chatViewModel.sendMessage()
        }

        await harness!.chatViewModel.awaitFirstToken()
        harness!.chatViewModel.stopGeneration()
        await sendTask.value

        let assistant = try XCTUnwrap(harness!.chatViewModel.messages.last)
        XCTAssertEqual(harness!.chatViewModel.messages.count, 2)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertFalse(assistant.content.isEmpty)
        XCTAssertNotEqual(assistant.content, backend.tokensToYield.joined())
        let persistedMessages = try await harness!.persistedMessages(for: session)
        XCTAssertEqual(persistedMessages.count, 2)
        XCTAssertEqual(persistedMessages.last?.content, assistant.content)
    }

    func test_switchingSessions_reloadsPersistedTranscriptForEachSession() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true

        harness = try ConsumerRuntimeHarness(
            inferenceService: InferenceService(backend: backend, name: "RuntimeMock")
        )

        let sessionA = try await harness!.createAndActivateSession(title: "Session A")
        backend.tokensToYield = ["Alpha", " reply"]
        harness!.chatViewModel.inputText = "Alpha question"
        await harness!.chatViewModel.sendMessage()

        let sessionB = try await harness!.createAndActivateSession(title: "Session B")
        backend.tokensToYield = ["Beta", " reply"]
        harness!.chatViewModel.inputText = "Beta question"
        await harness!.chatViewModel.sendMessage()

        await harness!.switchToSession(sessionA)
        XCTAssertEqual(
            harness!.chatViewModel.messages.map(\.content),
            ["Alpha question", "Alpha reply"]
        )

        await harness!.switchToSession(sessionB)
        XCTAssertEqual(
            harness!.chatViewModel.messages.map(\.content),
            ["Beta question", "Beta reply"]
        )
    }

    func test_init_throwingRuntime_restoresConfigurationAndCleansUp() throws {
        let originalConfiguration = BaseChatConfiguration.shared
        let tmp = FileManager.default.temporaryDirectory

        // Snapshot any existing harness tmp dirs so we can prove this run
        // didn't leak one.
        let prefix = "consumer-runtime-harness-"
        let before = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        let beforeHarnessDirs = Set(before.filter { $0.hasPrefix(prefix) })

        let backend = MockInferenceBackend()
        var makeModelContainerInvoked = false

        XCTAssertThrowsError(
            try ConsumerRuntimeHarness(
                inferenceService: InferenceService(backend: backend, name: "RuntimeMock"),
                makeModelContainer: {
                    makeModelContainerInvoked = true
                    throw URLError(.cannotOpenFile)
                }
            )
        )

        // Sanity check that we actually went down the makeModelContainer path
        // before throwing — without this, the assertions below could pass
        // trivially if the throwing closure had never been invoked.
        XCTAssertTrue(makeModelContainerInvoked)

        XCTAssertEqual(
            BaseChatConfiguration.shared.bundleIdentifier,
            originalConfiguration.bundleIdentifier,
            "Failed harness construction must roll BaseChatConfiguration.shared back to the value held before init"
        )

        let after = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        let afterHarnessDirs = Set(after.filter { $0.hasPrefix(prefix) })
        XCTAssertEqual(
            afterHarnessDirs.subtracting(beforeHarnessDirs),
            [],
            "Failed harness construction must remove the temp models directory it created"
        )
    }

    func test_refreshModels_includesBuiltInFoundationWhenAvailable() throws {
        let backend = MockInferenceBackend()
        harness = try ConsumerRuntimeHarness(
            inferenceService: InferenceService(backend: backend, name: "RuntimeMock"),
            foundationModelProvider: { true }
        )

        harness!.chatViewModel.refreshModels()

        XCTAssertEqual(harness!.chatViewModel.availableModels.count, 1)
        XCTAssertEqual(harness!.chatViewModel.availableModels.first?.modelType, .foundation)
    }

    func test_toolRegistry_survivesRuntimeBootstrap_andAdvertisesDefinitionsToBackend() async throws {
        let backend = MockInferenceBackend(
            capabilities: BackendCapabilities(
                supportedParameters: [.temperature, .topP, .repeatPenalty],
                maxContextTokens: 4096,
                supportsToolCalling: true
            )
        )
        backend.isModelLoaded = true
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "tool-1", toolName: "lookup_status", arguments: "{}")],
            [],
        ]
        backend.tokensToYieldPerTurn = [
            [],
            ["Tool", " complete"],
        ]

        let executor = CountingExecutor(name: "lookup_status")
        let registry = ToolRegistry()
        registry.register(executor)

        harness = try ConsumerRuntimeHarness(
            inferenceService: InferenceService(
                backend: backend,
                name: "RuntimeToolMock",
                toolRegistry: registry
            )
        )

        _ = try await harness!.createAndActivateSession(title: "Tool Session")
        harness!.chatViewModel.inputText = "Check runtime tools"

        await harness!.chatViewModel.sendMessage()

        XCTAssertEqual(backend.lastConfig?.tools.map(\.name), ["lookup_status"])
        XCTAssertEqual(executor.callCount, 1)
        XCTAssertEqual(harness!.chatViewModel.messages.last?.content, "Tool complete")
    }

    func test_toolRegistry_advertisedDefinitionsLimitBackendConfigWithoutUnregisteringTools() async throws {
        let backend = MockInferenceBackend(
            capabilities: BackendCapabilities(
                supportedParameters: [.temperature, .topP, .repeatPenalty],
                maxContextTokens: 4096,
                supportsToolCalling: true
            )
        )
        backend.isModelLoaded = true
        backend.tokensToYield = ["Done"]

        let visible = CountingExecutor(name: "visible_tool")
        let hidden = CountingExecutor(name: "hidden_tool")
        let registry = ToolRegistry()
        registry.register(visible)
        registry.register(hidden)
        registry.advertisedToolNames = ["visible_tool"]

        harness = try ConsumerRuntimeHarness(
            inferenceService: InferenceService(
                backend: backend,
                name: "RuntimeToolMock",
                toolRegistry: registry
            )
        )

        _ = try await harness!.createAndActivateSession(title: "Tool Session")
        harness!.chatViewModel.inputText = "Check runtime tools"

        await harness!.chatViewModel.sendMessage()

        XCTAssertEqual(backend.lastConfig?.tools.map(\.name), ["visible_tool"])
        XCTAssertTrue(registry.contains(name: "hidden_tool"))
    }
}

@MainActor
private final class CountingExecutor: ToolExecutor, @unchecked Sendable {
    let definition: ToolDefinition
    private(set) var callCount = 0

    init(name: String) {
        definition = ToolDefinition(name: name, description: "counts runtime harness tool calls")
    }

    nonisolated func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        await MainActor.run { self.callCount += 1 }
        return ToolResult(callId: "", content: #"{"status":"ok"}"#, errorKind: nil)
    }
}
