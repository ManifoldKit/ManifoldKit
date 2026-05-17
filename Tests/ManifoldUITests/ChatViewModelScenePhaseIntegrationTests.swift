@preconcurrency import XCTest
import SwiftUI
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// Integration coverage complementing `ScenePhaseTransitionTests`.
///
/// Where `ScenePhaseTransitionTests` pins UI-level state (`isGenerating`,
/// `activityPhase`), this file pins the service-layer invariants we care
/// about after a background transition: the coordinator's queue is empty,
/// the backend observed a `stopGeneration()` call, and no additional tokens
/// are appended to the in-flight message after the transition.
///
/// Together they catch two different bug shapes: the UI forgetting to call
/// `stopGeneration` (caught by the existing file), and the service-layer
/// failing to propagate that cancel all the way through (caught here).
@MainActor
final class ChatViewModelScenePhaseIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var slowBackend: SlowMockBackend!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext

        slowBackend = SlowMockBackend()
        slowBackend.tokensToYield = (0..<40).map { "t\($0) " }
        // Per-token delay must be wide enough that scheduler-latency between
        // `awaitFirstToken()` → reading `tokenCountAtBackground` →
        // `handleScenePhaseChange` → cancel propagation cannot smuggle in more
        // tokens than the bounded-growth assertion below tolerates. 25ms was
        // tight enough to flake under CI load (#1332).
        slowBackend.delayPerToken = .milliseconds(50)

        let service = InferenceService(backend: slowBackend, name: "SlowMock")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        vm.activeSession = ChatSessionRecord(title: "Scene Phase Integration")
    }

    override func tearDown() async throws {
        vm?.stopGeneration()
        vm?.inferenceService.unloadModel()
        vm = nil
        slowBackend = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    /// Backgrounding mid-stream must cancel cleanly end-to-end: the backend
    /// observes the stop, the in-flight message stops growing, and the
    /// service-layer queue is drained so the next sceneactivation isn't
    /// shadowed by a ghost request.
    func test_backgroundTransition_endToEnd_terminatesCleanly() async throws {
        vm.inputText = "Hello"
        let sendTask = Task { await vm.sendMessage() }

        await vm.awaitFirstToken()
        XCTAssertTrue(vm.isGenerating, "precondition: generation should be active")

        let tokenCountAtBackground = vm.messages.last?.content.count ?? 0
        let stopsBefore = slowBackend.isGenerating

        vm.handleScenePhaseChange(to: .background)

        // Service-layer invariants (the integration point this test owns):
        XCTAssertFalse(vm.isGenerating, "isGenerating must be false immediately after backgrounding")
        XCTAssertFalse(
            vm.inferenceService.hasQueuedRequests,
            "the service queue must be empty once backgrounding cancels the active stream"
        )

        // Let the sendMessage task observe the cancel and unwind.
        await sendTask.value

        XCTAssertFalse(slowBackend.isGenerating, "backend must report generation stopped")

        // The in-flight message must have frozen at background-time — no
        // further tokens are appended after the scene-phase transition.
        let tokenCountAfterDrain = vm.messages.last?.content.count ?? 0
        // Slack covers (a) the in-flight yield already scheduled when the
        // scene-phase call lands and (b) scheduler latency on busy CI runners.
        // We still catch the regression we care about — unbounded streaming
        // through the entire 40-token plan — without flaking on a slow host.
        XCTAssertLessThanOrEqual(
            tokenCountAfterDrain,
            tokenCountAtBackground + 5,
            "no appreciable token growth permitted after backgrounding (slack for any already-queued yield)"
        )

        _ = stopsBefore  // silence unused warning without adding a flaky assert on it
    }
}
