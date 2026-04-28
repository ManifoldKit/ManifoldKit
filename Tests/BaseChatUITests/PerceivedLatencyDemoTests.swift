import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

/// Demonstrates running the full `ChatViewModel.sendMessage()` flow through
/// a backend that models realistic streaming latency.
///
/// The intent is not to retrofit every existing test — it's to show that the
/// happy-path assistant content is preserved even when tokens arrive with a
/// TTFT pause and inter-token jitter. If a future UI change breaks streaming
/// assembly under realistic timing (e.g. batching the wrong slice), this
/// test will catch it while other `MockInferenceBackend`-based tests stay
/// green.
@MainActor
final class PerceivedLatencyDemoTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var backend: PerceivedLatencyBackend!

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        backend = PerceivedLatencyBackend(
            coldStartDelay: .milliseconds(0),
            timeToFirstToken: .milliseconds(100),
            interTokenJitter: .milliseconds(10)...(.milliseconds(30)),
            tokensToYield: ["Hello", ", ", "world", "!"]
        )
        // InferenceService(backend:name:) treats the supplied backend as
        // already loaded, so we must preload the backend too or generate()
        // will throw its own "No model loaded" guard.
        try await backend.loadModel(from: URL(fileURLWithPath: "/tmp/fake"), plan: .testStub(effectiveContextSize: 512))

        let service = InferenceService(backend: backend, name: "PerceivedLatency")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
    }

    override func tearDown() async throws {
        vm?.stopGeneration()
        vm?.inferenceService.unloadModel()
        vm = nil
        sessionManager = nil
        backend = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    func test_sendMessage_assemblesFullResponse_withRealisticLatency() async throws {
        let session = try await sessionManager.createSession(title: "Demo")
        sessionManager.activeSession = session
        await vm.switchToSession(session)

        vm.inputText = "Greet me"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[0].content, "Greet me")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(
            vm.messages[1].content, "Hello, world!",
            "Assistant content should equal the concatenated token stream even under jittered delivery"
        )
        XCTAssertFalse(vm.isGenerating)
    }
}
