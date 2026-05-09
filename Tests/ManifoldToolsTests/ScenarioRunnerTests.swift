#if Tools
import XCTest
import ManifoldInference
@testable import ManifoldTools

@MainActor
final class ScenarioRunnerTests: XCTestCase {

    // MARK: - Assertion evaluator

    func test_containsLiteralAssertion_passesWhenValuePresent() {
        let assertion = Scenario.Assertion(kind: "containsLiteral", value: "needle", values: nil, message: nil)
        let outcome = AssertionEvaluator.evaluate(assertion, finalAnswer: "the needle is here")
        XCTAssertTrue(outcome.passed)
    }

    func test_containsLiteralAssertion_failsWhenValueMissing() {
        let assertion = Scenario.Assertion(kind: "containsLiteral", value: "needle", values: nil, message: nil)
        let outcome = AssertionEvaluator.evaluate(assertion, finalAnswer: "nothing to see")
        XCTAssertFalse(outcome.passed, "evaluator should fail when literal is absent")
    }

    func test_containsAllAssertion_requiresEveryValue() {
        let assertion = Scenario.Assertion(
            kind: "containsAll",
            value: nil,
            values: ["a.txt", "b.txt"],
            message: nil
        )
        XCTAssertTrue(AssertionEvaluator.evaluate(assertion, finalAnswer: "a.txt b.txt").passed)
        XCTAssertFalse(AssertionEvaluator.evaluate(assertion, finalAnswer: "a.txt only").passed)
    }

    func test_toolInvokedAssertion_passesWhenToolDispatched() {
        let assertion = Scenario.Assertion(
            kind: "toolInvoked",
            value: "now",
            values: nil,
            message: nil
        )
        XCTAssertTrue(
            AssertionEvaluator.evaluate(assertion, finalAnswer: "anything", toolsInvoked: ["now"]).passed,
            "toolInvoked should pass when the named tool appears in toolsInvoked"
        )
    }

    func test_toolInvokedAssertion_failsWhenToolMissing() {
        // Honesty gate: the final answer matches the expected nonce, but the
        // tool was never called. Without this assertion kind, the harness
        // would pass a purely-hallucinated answer.
        let assertion = Scenario.Assertion(
            kind: "toolInvoked",
            value: "now",
            values: nil,
            message: nil
        )
        let outcome = AssertionEvaluator.evaluate(
            assertion,
            finalAnswer: "2099-01-01T00:00:00Z",
            toolsInvoked: []  // model answered without calling the tool
        )
        XCTAssertFalse(outcome.passed)
        XCTAssertTrue(outcome.message.contains("never dispatched"))
    }

    func test_unknownAssertionKind_fails() {
        let assertion = Scenario.Assertion(kind: "fuzzy", value: "x", values: nil, message: nil)
        XCTAssertFalse(AssertionEvaluator.evaluate(assertion, finalAnswer: "x").passed)
    }

    // MARK: - ScenarioLoader

    func test_scenarioLoader_decodesAllBuiltIn() throws {
        let scenarios = try ScenarioLoader.loadBuiltIn()
        XCTAssertEqual(scenarios.count, 4, "expected four built-in scenarios")
        let ids = scenarios.map(\.id).sorted()
        XCTAssertEqual(ids, ["01-now", "02-calc", "03-read", "04-list"])
        for s in scenarios {
            XCTAssertFalse(s.systemPrompt.isEmpty, "\(s.id) missing systemPrompt")
            XCTAssertFalse(s.requiredTools.isEmpty, "\(s.id) missing requiredTools")
            XCTAssertFalse(s.assertions.isEmpty, "\(s.id) missing assertions")
        }
    }

    // MARK: - Runner happy paths (scripted backend + real registry)

    func test_runner_executesNowToolAndQuotesFixture() async throws {
        let registry = ToolRegistry(tools: [NowTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "now", arguments: "{}"),
            .tokens([NowTool.defaultFixture])
        ])
        let scenario = Scenario(
            id: "test-now",
            description: "",
            systemPrompt: "sys",
            userPrompt: "what time is it?",
            requiredTools: ["now"],
            assertions: [
                Scenario.Assertion(kind: "containsLiteral", value: NowTool.defaultFixture, values: nil, message: nil)
            ],
            backend: Scenario.BackendSpec(kind: "mock", model: "scripted", fallbackModel: nil, temperature: 0, seed: nil, topK: nil)
        )
        let runner = ScenarioRunner(backend: backend, registry: registry)
        let outcome = try await runner.run(scenario)
        XCTAssertTrue(outcome.passed, "outcome should pass; answer=\(outcome.finalAnswer)")
        XCTAssertEqual(outcome.toolCallsExecuted, ["now"])
    }

    func test_runner_executesCalcToolAndQuotesAnswer() async throws {
        let registry = ToolRegistry(tools: [CalcTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "calc", arguments: #"{"a":7823,"op":"*","b":41}"#),
            .tokens(["320743"])
        ])
        let scenario = Scenario(
            id: "test-calc",
            description: "",
            systemPrompt: "sys",
            userPrompt: "compute",
            requiredTools: ["calc"],
            assertions: [
                Scenario.Assertion(kind: "containsLiteral", value: "320743", values: nil, message: nil)
            ],
            backend: Scenario.BackendSpec(kind: "mock", model: "scripted", fallbackModel: nil, temperature: 0, seed: nil, topK: nil)
        )
        let outcome = try await ScenarioRunner(backend: backend, registry: registry).run(scenario)
        XCTAssertTrue(outcome.passed)
    }

    func test_runner_honoursMaxIterationsOnLoopingTool() async throws {
        // Script keeps emitting tool calls; runner should bail after maxIterations
        // and run assertions against whatever text was captured (empty string here
        // → assertion fails → outcome.passed == false).
        let registry = ToolRegistry(tools: [NowTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "now", arguments: "{}"),
            .toolCall(name: "now", arguments: "{}"),
            .toolCall(name: "now", arguments: "{}")
        ])
        let scenario = Scenario(
            id: "test-loop",
            description: "",
            systemPrompt: "sys",
            userPrompt: "time",
            requiredTools: ["now"],
            assertions: [
                Scenario.Assertion(kind: "containsLiteral", value: "final-answer", values: nil, message: nil)
            ],
            backend: Scenario.BackendSpec(kind: "mock", model: "scripted", fallbackModel: nil, temperature: 0, seed: nil, topK: nil)
        )
        let runner = ScenarioRunner(backend: backend, registry: registry, maxIterations: 2)
        let outcome = try await runner.run(scenario)
        XCTAssertFalse(outcome.passed, "scenario should not pass once the runner aborts on iteration cap")
        XCTAssertEqual(outcome.toolCallsExecuted.count, 2, "should dispatch exactly maxIterations tool calls")
    }

    // MARK: - TranscriptLogger

    func test_transcriptLogger_writesOneJsonlRowPerEvent() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifold-tools-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }

        let logger = try TranscriptLogger(url: path)
        logger.append(.prompt(scenarioId: "t", system: "sys", user: "u"))
        logger.append(.toolCall(scenarioId: "t", name: "now", arguments: "{}"))
        logger.append(.final(scenarioId: "t", text: "done"))

        // Force flush by letting the logger go out of scope through an autoreleasepool.
        // FileHandle writes are synchronous so just reading the file back is enough.
        let data = try Data(contentsOf: path)
        let lines = data.split(separator: 0x0A).map { Data($0) }
        XCTAssertEqual(lines.count, 3, "should have one line per event")
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: line), "each row must be valid JSON")
        }
    }
}
#endif
