import XCTest
@testable import ManifoldFuzz
import ManifoldInference
import ManifoldTestSupport

@MainActor
final class SessionScriptRunnerTests: XCTestCase {

    /// Builds a service backed by a `MockInferenceBackend` that yields the
    /// given scripted reply. The `#if DEBUG` convenience initializer does
    /// the heavy lifting so we don't have to wire a factory for each test.
    private func makeService(replying tokens: [String] = ["ok"]) -> (InferenceService, MockInferenceBackend) {
        let mock = MockInferenceBackend()
        mock.tokensToYield = tokens
        mock.isModelLoaded = true // bypass the explicit load step
        let service = InferenceService(backend: mock, name: "SessionRunnerTest")
        return (service, mock)
    }

    func test_sendStep_enqueuesAndCapturesRecord() async throws {
        let (service, mock) = makeService(replying: ["hello", " there"])
        let runner = SessionScriptRunner(
            service: service,
            options: .init(modelId: "mock-1"),
            seed: 42
        )
        let script = SessionScript(
            id: "basic-send",
            steps: [.send(text: "hi")]
        )
        let capture = await runner.execute(script)

        XCTAssertEqual(capture.steps.count, 1)
        XCTAssertEqual(capture.steps[0].timeline, .executed)
        let record = try XCTUnwrap(capture.steps[0].record)
        XCTAssertEqual(record.raw, "hello there")
        XCTAssertEqual(record.model.id, "mock-1")
        XCTAssertEqual(mock.generateCallCount, 1)
    }

    func test_stopStep_invokesStopGeneration() async {
        let (service, mock) = makeService()
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "just-stop",
            steps: [.stop]
        )
        let capture = await runner.execute(script)

        XCTAssertEqual(capture.steps.count, 1)
        XCTAssertEqual(capture.steps[0].timeline, .stopRequested)
        XCTAssertNil(capture.steps[0].record)
        XCTAssertEqual(mock.stopCallCount, 1)
    }

    func test_editStep_mutatesMessageArray_withoutGeneration() async {
        let (service, mock) = makeService(replying: ["r1"])
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "edit-no-regen",
            steps: [
                .send(text: "original"),
                .edit(messageIndex: 0, newText: "edited"),
            ]
        )
        _ = await runner.execute(script)
        // Edit alone should NOT trigger a second generate.
        XCTAssertEqual(mock.generateCallCount, 1)
    }

    func test_regenerateStep_dropsAssistantAndEnqueuesAgain() async {
        let (service, mock) = makeService(replying: ["first"])
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "regen",
            steps: [
                .send(text: "hello"),
                .regenerate,
            ]
        )
        _ = await runner.execute(script)
        XCTAssertEqual(mock.generateCallCount, 2,
            "regenerate must re-enqueue and produce a second generate() call")
    }

    func test_deleteWithInvalidIndex_emitsTimelineEvent() async {
        let (service, _) = makeService()
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "bad-delete",
            steps: [.delete(messageIndex: 999)]
        )
        let capture = await runner.execute(script)
        XCTAssertEqual(capture.steps[0].timeline, .indexOutOfRange)
    }

    func test_stepOrdering_preservesScriptOrder() async {
        let (service, _) = makeService(replying: ["hi"])
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "ordering",
            steps: [
                .send(text: "one"),
                .stop,
                .edit(messageIndex: 0, newText: "two"),
                .regenerate,
            ]
        )
        let capture = await runner.execute(script)
        XCTAssertEqual(capture.steps.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(capture.steps.map(\.timeline), [
            .executed, .stopRequested, .edited, .executed,
        ])
    }

    func test_turnRecords_filtersNonExecutedSteps() async {
        let (service, _) = makeService(replying: ["r"])
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "filter",
            steps: [.send(text: "a"), .edit(messageIndex: 0, newText: "b"), .regenerate]
        )
        let capture = await runner.execute(script)
        XCTAssertEqual(capture.turnRecords.count, 2,
            "only the two enqueue-producing steps should appear in turnRecords")
    }
}
