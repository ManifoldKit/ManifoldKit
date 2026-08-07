import XCTest
import ManifoldInference
@testable import ManifoldTools

final class ScenarioCLIHarnessTests: XCTestCase {

    // MARK: - parseCommonFlags

    func test_parseCommonFlags_defaultsWhenNoFlagsGiven() {
        let defaultOutput = URL(fileURLWithPath: "/tmp/default.jsonl")
        guard case .options(let options, let remainder) = ScenarioCLIHarness.parseCommonFlags([], defaultOutput: defaultOutput) else {
            return XCTFail("expected .options")
        }
        XCTAssertEqual(options.scenarioFilter, "all")
        XCTAssertEqual(options.output, defaultOutput)
        XCTAssertNil(options.fixturesRoot)
        XCTAssertEqual(options.extraTools, 0)
        XCTAssertFalse(options.list)
        XCTAssertEqual(options.repeatIndex, 0)
        XCTAssertTrue(remainder.isEmpty)
    }

    func test_parseCommonFlags_parsesEveryCommonFlag() {
        let argv = [
            "--scenario", "now",
            "--output", "/tmp/out.jsonl",
            "--fixtures-root", "/tmp/fixtures",
            "--extra-tools", "3",
            "--repeat-index", "2",
            "--list",
        ]
        guard case .options(let options, let remainder) = ScenarioCLIHarness.parseCommonFlags(
            argv, defaultOutput: URL(fileURLWithPath: "/tmp/default.jsonl")
        ) else {
            return XCTFail("expected .options")
        }
        XCTAssertEqual(options.scenarioFilter, "now")
        XCTAssertEqual(options.output, URL(fileURLWithPath: "/tmp/out.jsonl"))
        XCTAssertEqual(options.fixturesRoot, URL(fileURLWithPath: "/tmp/fixtures", isDirectory: true))
        XCTAssertEqual(options.extraTools, 3)
        XCTAssertEqual(options.repeatIndex, 2)
        XCTAssertTrue(options.list)
        XCTAssertTrue(remainder.isEmpty)
    }

    func test_parseCommonFlags_missingRepeatIndexValueFails() {
        guard case .failure = ScenarioCLIHarness.parseCommonFlags(
            ["--repeat-index"], defaultOutput: URL(fileURLWithPath: "/tmp/default.jsonl")
        ) else {
            return XCTFail("expected .failure for --repeat-index with no value")
        }
    }

    func test_parseCommonFlags_negativeRepeatIndexFails() {
        guard case .failure = ScenarioCLIHarness.parseCommonFlags(
            ["--repeat-index", "-1"], defaultOutput: URL(fileURLWithPath: "/tmp/default.jsonl")
        ) else {
            return XCTFail("expected .failure for negative --repeat-index")
        }
    }

    func test_parseCommonFlags_passesThroughUnknownFlagsInOrder() {
        let argv = ["--backend", "ollama", "--scenario", "now", "--model", "a,b"]
        guard case .options(let options, let remainder) = ScenarioCLIHarness.parseCommonFlags(
            argv, defaultOutput: URL(fileURLWithPath: "/tmp/default.jsonl")
        ) else {
            return XCTFail("expected .options")
        }
        XCTAssertEqual(options.scenarioFilter, "now")
        XCTAssertEqual(remainder, ["--backend", "ollama", "--model", "a,b"])
    }

    func test_parseCommonFlags_detectsHelp() {
        for argv in [["--help"], ["-h"], ["--scenario", "now", "--help"]] {
            guard case .helpRequested = ScenarioCLIHarness.parseCommonFlags(
                argv, defaultOutput: URL(fileURLWithPath: "/tmp/default.jsonl")
            ) else {
                return XCTFail("expected .helpRequested for \(argv)")
            }
        }
    }

    func test_parseCommonFlags_missingValueFails() {
        for argv in [["--scenario"], ["--output"], ["--fixtures-root"], ["--extra-tools"]] {
            guard case .failure = ScenarioCLIHarness.parseCommonFlags(
                argv, defaultOutput: URL(fileURLWithPath: "/tmp/default.jsonl")
            ) else {
                return XCTFail("expected .failure for \(argv)")
            }
        }
    }

    func test_parseCommonFlags_negativeExtraToolsFails() {
        guard case .failure = ScenarioCLIHarness.parseCommonFlags(
            ["--extra-tools", "-1"], defaultOutput: URL(fileURLWithPath: "/tmp/default.jsonl")
        ) else {
            return XCTFail("expected .failure for negative --extra-tools")
        }
    }

    // MARK: - filterScenarios

    private func makeScenario(id: String) -> Scenario {
        Scenario(
            id: id,
            description: "",
            systemPrompt: "sys",
            userPrompt: "prompt",
            requiredTools: [],
            assertions: [],
            backend: Scenario.BackendSpec(kind: "mock", model: "scripted", fallbackModel: nil, temperature: 0, seed: nil, topK: nil)
        )
    }

    func test_filterScenarios_allReturnsEveryScenario() throws {
        let scenarios = [makeScenario(id: "a"), makeScenario(id: "b")]
        let filtered = try ScenarioCLIHarness.filterScenarios(scenarios, matching: "all")
        XCTAssertEqual(filtered, scenarios)
    }

    func test_filterScenarios_matchesById() throws {
        let scenarios = [makeScenario(id: "a"), makeScenario(id: "b")]
        let filtered = try ScenarioCLIHarness.filterScenarios(scenarios, matching: "b")
        XCTAssertEqual(filtered.map(\.id), ["b"])
    }

    func test_filterScenarios_throwsOnNoMatch() {
        let scenarios = [makeScenario(id: "a")]
        XCTAssertThrowsError(try ScenarioCLIHarness.filterScenarios(scenarios, matching: "nonexistent")) { error in
            guard case ScenarioCLIHarness.FilterError.noMatch(let id) = error else {
                return XCTFail("expected .noMatch, got \(error)")
            }
            XCTAssertEqual(id, "nonexistent")
        }
    }

    // MARK: - resolveFixturesRoot

    func test_resolveFixturesRoot_prefersExplicitOverride() {
        let override = URL(fileURLWithPath: "/tmp/custom-fixtures", isDirectory: true)
        XCTAssertEqual(ScenarioCLIHarness.resolveFixturesRoot(override), override)
    }

    func test_resolveFixturesRoot_defaultsToBundledRoot() {
        XCTAssertEqual(ScenarioCLIHarness.resolveFixturesRoot(nil), ToolFixtures.bundledRoot())
    }

    // MARK: - finish

    func test_finish_passReturnsZero() {
        XCTAssertEqual(ScenarioCLIHarness.finish(allPassed: true, transcriptPath: URL(fileURLWithPath: "/tmp/t.jsonl")), 0)
    }

    func test_finish_failReturnsOne() {
        XCTAssertEqual(ScenarioCLIHarness.finish(allPassed: false, transcriptPath: URL(fileURLWithPath: "/tmp/t.jsonl")), 1)
    }

    // MARK: - runAll

    @MainActor
    func test_runAll_aggregatesPassAcrossScenariosAndModels() async throws {
        let scenario = makeScenario(id: "now")
        var seen: [(String, String)] = []
        let allPassed = await ScenarioCLIHarness.runAll(
            scenarios: [scenario],
            displayName: "mock",
            modelsFor: { _ in ["model-a", "model-b"] }
        ) { scenario, model in
            seen.append((scenario.id, model))
            return ScenarioRunner.Outcome(
                scenarioId: scenario.id,
                finalAnswer: "ok",
                toolCallsExecuted: [],
                toolResults: [],
                assertions: [AssertionOutcome(passed: true, message: "ok")]
            )
        }
        XCTAssertTrue(allPassed)
        XCTAssertEqual(seen.map(\.1), ["model-a", "model-b"])
    }

    @MainActor
    func test_runAll_oneFailingAssertionFailsTheAggregate() async throws {
        let scenario = makeScenario(id: "now")
        let allPassed = await ScenarioCLIHarness.runAll(
            scenarios: [scenario],
            displayName: "mock",
            modelsFor: { _ in ["model-a"] }
        ) { scenario, _ in
            ScenarioRunner.Outcome(
                scenarioId: scenario.id,
                finalAnswer: "wrong",
                toolCallsExecuted: [],
                toolResults: [],
                assertions: [AssertionOutcome(passed: false, message: "nope")]
            )
        }
        XCTAssertFalse(allPassed)
    }

    @MainActor
    func test_runAll_thrownErrorIsCaughtAndCountsAsFailureWithoutAbortingTheSweep() async throws {
        struct Boom: Error {}
        let scenarios = [makeScenario(id: "first"), makeScenario(id: "second")]
        var ran: [String] = []
        let allPassed = await ScenarioCLIHarness.runAll(
            scenarios: scenarios,
            displayName: "mock",
            modelsFor: { _ in ["model-a"] }
        ) { scenario, _ in
            ran.append(scenario.id)
            if scenario.id == "first" {
                throw Boom()
            }
            return ScenarioRunner.Outcome(
                scenarioId: scenario.id,
                finalAnswer: "ok",
                toolCallsExecuted: [],
                toolResults: [],
                assertions: [AssertionOutcome(passed: true, message: "ok")]
            )
        }
        XCTAssertFalse(allPassed, "a thrown error in one cell must fail the aggregate")
        XCTAssertEqual(ran, ["first", "second"], "a thrown error must not abort the rest of the sweep")
    }
}
