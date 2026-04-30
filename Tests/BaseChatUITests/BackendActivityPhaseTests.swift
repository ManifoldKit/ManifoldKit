@preconcurrency import XCTest
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

@MainActor
final class BackendActivityPhaseTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private nonisolated(unsafe) var harnesses: [TestChatViewModelHarness] = []

    override func tearDown() async throws {
        for harness in harnesses { harness.cleanup() }
        harnesses.removeAll()
        try await super.tearDown()
    }

    private func makeViewModelWithMock(
        mock: MockInferenceBackend = MockInferenceBackend()
    ) -> (ChatViewModel, MockInferenceBackend) {
        let harness = try! makeTestChatViewModel(mock: mock, activateSession: true)
        harnesses.append(harness)
        return (harness.vm, harness.mock!)
    }

    private func makeViewModelWithSlowMock(
        tokenCount: Int = 5,
        delayMilliseconds: Int = 20
    ) -> (ChatViewModel, SlowMockBackend) {
        let mock = SlowMockBackend(tokenCount: tokenCount, delayMilliseconds: delayMilliseconds)
        let service = InferenceService(backend: mock, name: "SlowMock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.activeSession = ChatSessionRecord(title: "Test")
        return (vm, mock)
    }

    // MARK: - Initial State

    func testInitialPhaseIsIdle() {
        let vm = ChatViewModel()
        XCTAssertEqual(vm.activityPhase, .idle)
    }

    // MARK: - Backward Compatibility

    func testIsLoadingDerivedFromModelLoadingPhase() {
        let vm = ChatViewModel()
        XCTAssertFalse(vm.isLoading)

        vm.transitionPhase(to: .modelLoading(progress: nil))
        XCTAssertTrue(vm.isLoading)

        vm.transitionPhase(to: .modelLoading(progress: 0.5))
        XCTAssertTrue(vm.isLoading)

        vm.transitionPhase(to: .idle)
        XCTAssertFalse(vm.isLoading)
    }

    func testIsGeneratingDerivedFromStreamingPhases() {
        let vm = ChatViewModel()
        XCTAssertFalse(vm.isGenerating)

        vm.transitionPhase(to: .waitingForFirstToken)
        XCTAssertTrue(vm.isGenerating)

        vm.transitionPhase(to: .streaming)
        XCTAssertTrue(vm.isGenerating)

        vm.transitionPhase(to: .idle)
        XCTAssertFalse(vm.isGenerating)
    }

    func testIsLoadingFalseWhenGenerating() {
        let vm = ChatViewModel()
        vm.transitionPhase(to: .waitingForFirstToken)
        vm.transitionPhase(to: .streaming)
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.isGenerating)
    }

    func testIsGeneratingFalseWhenLoading() {
        let vm = ChatViewModel()
        vm.transitionPhase(to: .modelLoading(progress: 0.3))
        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isGenerating)
    }

    // MARK: - onGeneratingChanged Hook

    func testOnGeneratingChangedFiringOnPhaseTransitions() {
        let vm = ChatViewModel()
        var observations: [Bool] = []
        vm.onGeneratingChanged = { observations.append($0) }

        vm.transitionPhase(to: .waitingForFirstToken)
        vm.transitionPhase(to: .streaming)
        vm.transitionPhase(to: .idle)

        // waitingForFirstToken: generating becomes true
        // streaming: generating stays true -- no fire
        // idle: generating becomes false
        XCTAssertEqual(observations, [true, false])
    }

    // MARK: - Phase Transitions During Generation

    func testPhaseTransitionsDuringGeneration() async {
        let (vm, _) = makeViewModelWithSlowMock(tokenCount: 3, delayMilliseconds: 30)

        XCTAssertEqual(vm.activityPhase, .idle)

        vm.inputText = "Hello"
        let sendTask = Task { await vm.sendMessage() }

        // Wait for generation to start
        await vm.awaitGenerating(true)
        // Phase should be waitingForFirstToken or streaming (depending on timing)
        XCTAssertTrue(vm.isGenerating)

        // Wait for first token to arrive, which transitions to .streaming
        await vm.awaitFirstToken()
        XCTAssertEqual(vm.activityPhase, .streaming)

        // Let generation finish
        await sendTask.value
        XCTAssertEqual(vm.activityPhase, .idle)
    }

    // MARK: - Stop Generation Resets Phase

    func testStopGenerationResetsToIdle() async {
        let (vm, _) = makeViewModelWithSlowMock(tokenCount: 20, delayMilliseconds: 50)

        vm.inputText = "Hello"
        let sendTask = Task { await vm.sendMessage() }
        await vm.awaitGenerating(true)
        await vm.awaitFirstToken()
        XCTAssertEqual(vm.activityPhase, .streaming)

        vm.stopGeneration()
        XCTAssertEqual(vm.activityPhase, .idle)

        await sendTask.value
    }

    // MARK: - Fast Generation (instant tokens)

    func testFastGenerationTransitionsToIdleWhenDone() async {
        let (vm, _) = makeViewModelWithMock()

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(vm.activityPhase, .idle)
        XCTAssertFalse(vm.isGenerating)
    }

    // MARK: - Equatable

    func testBackendActivityPhaseEquality() {
        XCTAssertEqual(BackendActivityPhase.idle, BackendActivityPhase.idle)
        XCTAssertEqual(BackendActivityPhase.streaming, BackendActivityPhase.streaming)
        XCTAssertEqual(BackendActivityPhase.waitingForFirstToken, BackendActivityPhase.waitingForFirstToken)
        XCTAssertEqual(
            BackendActivityPhase.modelLoading(progress: 0.5),
            BackendActivityPhase.modelLoading(progress: 0.5)
        )
        XCTAssertNotEqual(
            BackendActivityPhase.modelLoading(progress: 0.5),
            BackendActivityPhase.modelLoading(progress: 0.7)
        )
        XCTAssertNotEqual(BackendActivityPhase.idle, BackendActivityPhase.streaming)
    }
}
