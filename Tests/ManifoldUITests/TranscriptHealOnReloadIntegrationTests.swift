@preconcurrency import XCTest
@testable import ManifoldUI
@testable import ManifoldInference
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldTestSupport

/// Integration test for issue #629: a session whose persisted transcript
/// contains a `.toolCall` part with no matching `.toolResult` (because the
/// process was killed mid-tool) must be healed on session reload so that the
/// next-turn cloud-API request is well-formed.
///
/// Uses real ``ChatViewModel`` + in-memory SwiftData persistence; the inference
/// service has a mock backend that never actually runs. The pipeline under
/// test is `persistence.insertMessage` → `vm.switchToSession` → `loadMessages`
/// → `TranscriptHealer.heal` → `vm.messages`.
@MainActor
final class TranscriptHealOnReloadIntegrationTests: XCTestCase {

    private var vm: ChatViewModel!
    private var mock: MockInferenceBackend!
    private var stack: InMemoryPersistenceHarness.Stack!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "MockHealReload")
        vm = ChatViewModel(inferenceService: service)
        stack = try InMemoryPersistenceHarness.make()
        vm.configure(persistence: stack.provider)
    }

    override func tearDown() async throws {
        vm = nil
        mock = nil
        stack = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeSession() async -> ChatSessionRecord {
        let session = ChatSessionRecord(title: "Heal-On-Reload")
        try! await stack.provider.insertSession(session)
        return session
    }

    /// All `.toolCall` ids that have no matching `.toolResult` anywhere in the
    /// transcript. The "valid cloud-API history payload" assertion in this
    /// suite collapses to "this set is empty" — both Anthropic's and OpenAI's
    /// validators reject any history with a non-empty version of this set.
    private func orphanCallIDs(in records: [ChatMessageRecord]) -> Set<String> {
        var calls: Set<String> = []
        var results: Set<String> = []
        for r in records {
            for part in r.contentParts {
                switch part {
                case .toolCall(let c): calls.insert(c.id)
                case .toolResult(let res): results.insert(res.callId)
                default: break
                }
            }
        }
        return calls.subtracting(results)
    }

    // MARK: - Tests

    func test_sessionReload_synthesisesResultForOrphanToolCall() async throws {
        let session = await makeSession()
        let userMsg = ChatMessageRecord(
            role: .user,
            content: "Write a file",
            timestamp: Date(timeIntervalSince1970: 1000),
            sessionID: session.id
        )
        let orphanCall = ToolCall(
            id: "call-orphan-1",
            toolName: "writeFile",
            arguments: "{\"path\":\"/tmp/x\",\"contents\":\"hi\"}"
        )
        let assistantMsg = ChatMessageRecord(
            role: .assistant,
            contentParts: [.text("On it"), .toolCall(orphanCall)],
            timestamp: Date(timeIntervalSince1970: 1001),
            sessionID: session.id
        )
        try await stack.provider.insertMessage(userMsg)
        try await stack.provider.insertMessage(assistantMsg)

        // Sanity: the persisted transcript has an orphan before reload.
        let preReload = try await stack.provider.fetchMessages(for: session.id)
        XCTAssertEqual(orphanCallIDs(in: preReload), ["call-orphan-1"])

        // Reload via the ChatViewModel — this is the production code path.
        await vm.switchToSession(session)

        // Acceptance: the in-memory transcript no longer has any orphans.
        XCTAssertTrue(
            orphanCallIDs(in: vm.messages).isEmpty,
            "Reloaded transcript must not contain orphan tool calls — cloud APIs reject these"
        )

        // Acceptance: the synthesised result is present, marked .cancelled,
        // and includes the original arguments.
        let allParts = vm.messages.flatMap(\.contentParts)
        let synthesised = allParts.compactMap { part -> ToolResult? in
            if case .toolResult(let r) = part, r.callId == "call-orphan-1" { return r }
            return nil
        }
        XCTAssertEqual(synthesised.count, 1, "Exactly one synthesised result for the orphan")
        XCTAssertEqual(synthesised.first?.errorKind, .cancelled)
        XCTAssertTrue(synthesised.first?.content.contains("interrupted") ?? false)
        XCTAssertTrue(
            synthesised.first?.content.contains("/tmp/x") ?? false,
            "Synthesised content should reference the original arguments"
        )
    }

    func test_sessionReload_doesNotTouchPairedToolCall() async throws {
        let session = await makeSession()
        let call = ToolCall(id: "paired-1", toolName: "search", arguments: "{}")
        let result = ToolResult(callId: "paired-1", content: "ok")
        let assistantMsg = ChatMessageRecord(
            role: .assistant,
            contentParts: [.toolCall(call), .toolResult(result), .text("done")],
            timestamp: Date(timeIntervalSince1970: 1000),
            sessionID: session.id
        )
        try await stack.provider.insertMessage(assistantMsg)

        await vm.switchToSession(session)

        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(
            vm.messages[0].contentParts.count, 3,
            "Already-resolved tool calls must not gain a synthesised result"
        )
    }
}
