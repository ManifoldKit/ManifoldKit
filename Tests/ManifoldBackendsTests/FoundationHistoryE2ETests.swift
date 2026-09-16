#if canImport(FoundationModels)
import XCTest
import ManifoldInference
import ManifoldFoundation

/// Real engine → Foundation proof. Structural translation is covered separately
/// by FoundationConversationTests on hosts without Apple Intelligence.
@available(iOS 26, macOS 26, *)
@MainActor
final class FoundationHistoryE2ETests: XCTestCase {
    private var backends: [FoundationBackend] = []

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(ProcessInfo.processInfo.isOperatingSystemAtLeast(
            .init(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ), "FoundationModels requires iOS 26 / macOS 26")
        try XCTSkipUnless(FoundationBackend.isAvailable, "Requires Apple Intelligence")
        let ready = await FoundationBackend.probeIsReady()
        try XCTSkipUnless(ready, "Apple Intelligence model is not ready")
    }

    override func tearDown() async throws {
        for backend in backends { await backend.unloadModelAndWait() }
        backends = []
        try await super.tearDown()
    }

    private func load() async throws -> FoundationBackend {
        let backend = FoundationBackend()
        try await backend.loadModel(from: URL(fileURLWithPath: "/dev/null"), plan: .systemManaged(requestedContextSize: 4096))
        backends.append(backend)
        return backend
    }

    private func answer(_ service: InferenceService, history: [StructuredMessage], instructions: String? = nil,
                        config: GenerationConfig = GenerationConfig(maxOutputTokens: 64)) async throws -> String {
        let (_, stream) = try service.enqueue(structuredMessages: history, systemPrompt: instructions, config: config)
        var text = ""
        for try await event in stream.events {
            if case .token(let token) = event { text += token }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Sabotage: restore SDK session reuse / discard hints.history. The trimmed
    // request leaks TANGERINE and the reopened request loses it.
    func test_canonicalHistory_trimsRestoresAndSurvivesReset() async throws {
        let backend = try await load()
        let service = InferenceService(backend: backend, name: "Foundation")
        let first = StructuredMessage(role: "user", content: "Remember this word: TANGERINE. Reply only OK.")
        let question = StructuredMessage(role: "user", content: "What word did I ask you to remember? Reply only that word, or UNKNOWN if no word was provided.")
        let instructions = "Answer exactly as instructed. Do not guess a remembered word. If absent from this conversation, answer UNKNOWN."
        let acknowledgement = try await answer(service, history: [first], instructions: instructions)
        let trimmed = try await answer(service, history: [question], instructions: instructions)
        XCTAssertEqual(trimmed, "UNKNOWN")
        let history = [first, StructuredMessage(role: "assistant", content: acknowledgement), question]
        let reopened = InferenceService(backend: try await load(), name: "Foundation")
        let restored = try await answer(reopened, history: history, instructions: instructions)
        XCTAssertEqual(restored, "TANGERINE")
        backend.resetConversation()
        let afterReset = try await answer(service, history: history, instructions: instructions)
        XCTAssertEqual(afterReset, "TANGERINE")
    }

    func test_toolApprovalResultAndDenial_reachFinalAnswer() async throws {
        for allowed in [true, false] {
            let counter = InvocationCounter()
            let tool = MarkerTool(counter: counter)
            let service = InferenceService(
                backend: try await load(), name: "Foundation",
                toolRegistry: ToolRegistry(tools: [tool]),
                toolApprovalGate: ApprovalGate(allowed: allowed, counter: counter)
            )
            var config = GenerationConfig(maxOutputTokens: 128)
            config.temperature = 0
            config.tools = [tool.definition]
            config.maxToolIterations = 3
            let response = try await answer(service, history: [.init(role: "user", content:
                "You must call read_marker exactly once before answering. Do not guess the marker or whether access is allowed. After receiving the tool result, copy the successful marker verbatim; if the tool result reports permissionDenied, reply only DENIED and do not retry."
            )], config: config)
            XCTAssertEqual(response, allowed ? "TOOL_RESULT_COBALT_42" : "DENIED")
            let counts = await counter.counts()
            XCTAssertEqual(counts.approvals, 1)
            XCTAssertEqual(counts.executions, allowed ? 1 : 0)
        }
    }

    private actor InvocationCounter {
        var approvals = 0
        var executions = 0
        func approve() { approvals += 1 }
        func execute() { executions += 1 }
        func counts() -> (approvals: Int, executions: Int) { (approvals, executions) }
    }

    private struct MarkerTool: ToolExecutor {
        let counter: InvocationCounter
        let requiresApproval = true
        let definition = ToolDefinition(name: "read_marker", description: "Return the marker from a local test fixture.",
                                        parameters: .object(["type": .string("object"), "properties": .object([:])]))
        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            await counter.execute()
            return ToolResult(callId: "", content: "TOOL_RESULT_COBALT_42", errorKind: nil)
        }
    }

    private struct ApprovalGate: ToolApprovalGate {
        let allowed: Bool
        let counter: InvocationCounter
        func approve(_ call: ToolCall) async -> ToolApprovalDecision {
            await counter.approve()
            return allowed ? .approved : .denied(reason: "EXPERIMENT_DENIED")
        }
    }
}
#endif
