@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

// MARK: - PostGenerationTask Tests

/// Tests for ``ChatViewModel/postGenerationTasks`` lifecycle:
/// invocation, execution order, error isolation, and cancellation on session reset.
@MainActor
final class PostGenerationTaskTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var mock: MockInferenceBackend!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Hello", " world"]

        let service = InferenceService(backend: mock, name: "MockPost")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: SwiftDataPersistenceProvider(modelContext: context), autoLoad: false)
    }

    override func tearDown() async throws {
        vm = nil
        sessionManager = nil
        mock = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createAndActivateSession(title: String = "Test") async -> ChatSessionRecord {
        let session = try! await sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    // MARK: - Basic Invocation

    func test_postGenerationTask_calledAfterGeneration() async {
        await createAndActivateSession()
        let task = MockPostGenerationTask()
        vm.postGenerationTasks = [task]

        mock.tokensToYield = ["Hello", " world"]
        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        // Sabotage verified: removing vm.postGenerationTasks = [task] causes callCount to remain 0
        XCTAssertEqual(task.callCount, 1, "Task should be called once after generation")
    }

    func test_postGenerationTask_receivesCompletedMessage() async {
        await createAndActivateSession()
        let task = MockPostGenerationTask()
        vm.postGenerationTasks = [task]

        mock.tokensToYield = ["Hello", " world"]
        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        XCTAssertEqual(task.receivedMessages.first?.content, "Hello world")
        XCTAssertEqual(task.receivedMessages.first?.role, .assistant)
    }

    func test_postGenerationTask_receivesActiveSession() async {
        let session = await createAndActivateSession(title: "My Session")
        let task = MockPostGenerationTask()
        vm.postGenerationTasks = [task]

        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        XCTAssertEqual(task.receivedSessions.first?.id, session.id)
    }

    // MARK: - Execution Order

    func test_multiplePostGenerationTasks_runInRegistrationOrder() async {
        await createAndActivateSession()

        let order = ActorBox<[Int]>([])
        let task1 = OrderCapturingTask(index: 1, box: order)
        let task2 = OrderCapturingTask(index: 2, box: order)
        let task3 = OrderCapturingTask(index: 3, box: order)

        vm.postGenerationTasks = [task1, task2, task3]

        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        let callOrder = await order.value
        XCTAssertEqual(callOrder, [1, 2, 3], "Tasks must run in registration order")
    }

    // MARK: - Error Isolation

    func test_throwingTask_doesNotCancelSubsequentTasks() async {
        await createAndActivateSession()

        struct TestError: Error {}
        let failingTask = MockPostGenerationTask()
        failingTask.errorToThrow = TestError()
        let followingTask = MockPostGenerationTask()

        vm.postGenerationTasks = [failingTask, followingTask]

        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        XCTAssertEqual(failingTask.callCount, 1, "Throwing task should still be called")
        // Sabotage verified: removing the do/catch in ChatViewModel's task loop causes followingTask.callCount to be 0
        XCTAssertEqual(followingTask.callCount, 1, "Task after a throwing task should still run")
    }

    func test_throwingTask_surfacesErrorInBackgroundTaskError() async {
        await createAndActivateSession()

        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "Background error" }
        }

        let failingTask = MockPostGenerationTask()
        failingTask.errorToThrow = TestError()
        vm.postGenerationTasks = [failingTask]

        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        XCTAssertNotNil(vm.backgroundTaskError, "backgroundTaskError should be set when a task throws")
        XCTAssert(vm.backgroundTaskError is TestError, "Expected TestError but got \(String(describing: vm.backgroundTaskError))")
    }

    func test_successfulTask_doesNotSetBackgroundTaskError() async {
        await createAndActivateSession()

        let task = MockPostGenerationTask()
        vm.postGenerationTasks = [task]

        vm.inputText = "Hi"
        await vm.sendMessage()
        await vm.backgroundTask?.value

        XCTAssertNil(vm.backgroundTaskError, "backgroundTaskError should remain nil when tasks succeed")
    }

    // MARK: - Cancellation on Session Reset

    func test_postGenerationTask_cancelledOnSessionReset() async throws {
        await createAndActivateSession(title: "Session A")
        let sessionB = try! await sessionManager.createSession(title: "Session B")

        let slowTask = MockPostGenerationTask()
        slowTask.runDelay = .seconds(10)  // Long enough to remain in-flight during session switch.
        let quickTask = MockPostGenerationTask()
        vm.postGenerationTasks = [slowTask, quickTask]

        mock.tokensToYield = ["Hi"]
        vm.inputText = "Hello"
        await vm.sendMessage()

        // Capture the in-flight task before switching sessions.
        let inflight = vm.backgroundTask

        // Background task is now running (slowTask sleeping for 10 s).
        // Switching session cancels it before quickTask gets a chance to run.
        await vm.switchToSession(sessionB)

        // Wait for the cancelled task to finish cooperatively — deterministic, no fixed sleep.
        await inflight?.value

        XCTAssertEqual(quickTask.callCount, 0, "Task after cancelled slow task should not run")
    }

    // MARK: - No Task Fired for Empty Response

    func test_postGenerationTask_notCalledForEmptyResponse() async {
        await createAndActivateSession()

        let task = MockPostGenerationTask()
        vm.postGenerationTasks = [task]

        mock.tokensToYield = []  // Empty stream — no content.
        vm.inputText = "Hi"
        await vm.sendMessage()

        // backgroundTask is nil (never scheduled) so awaiting it is a no-op.
        await vm.backgroundTask?.value

        XCTAssertNil(vm.backgroundTask, "backgroundTask should not be scheduled for empty responses")
        XCTAssertEqual(task.callCount, 0, "Task should not be called when the assistant message is empty")
    }
}

// MARK: - Test Support

/// Actor box for capturing ordered call indices safely across concurrency boundaries.
private actor ActorBox<T: Sendable> {
    var value: T
    init(_ initial: T) { value = initial }
    func append(_ element: Int) where T == [Int] { value.append(element) }
}

private final class OrderCapturingTask: PostGenerationTask, Sendable {
    let index: Int
    let box: ActorBox<[Int]>
    init(index: Int, box: ActorBox<[Int]>) {
        self.index = index
        self.box = box
    }
    func run(message: ChatMessageRecord, session: ChatSessionRecord) async throws {
        await box.append(index)
    }
}
