import XCTest
import ManifoldInference
@testable import ManifoldTools

@MainActor
final class ScenarioRunnerTests: XCTestCase {

    /// Builds a `ScenarioRunner` driving the production `InferenceService`
    /// orchestration path: the scripted backend is injected together with the
    /// tool registry so `GenerationQueue` → `GenerationToolDispatchLoop` runs
    /// the tool loop, renders the prompt template, and injects tool
    /// definitions — exactly what production does (#1983).
    private func makeRunner(
        backend: ScriptedBackend,
        registry: ToolRegistry,
        maxIterations: Int = 6
    ) -> ScenarioRunner {
        let service = InferenceService(backend: backend, name: "scripted", toolRegistry: registry)
        return ScenarioRunner(service: service, maxIterations: maxIterations)
    }

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

    func test_toolResultContainsAssertion_requiresToolOutput() {
        let assertion = Scenario.Assertion(
            kind: "toolResultContains",
            value: "read_file",
            values: ["MEETING-NOTES-754", "Aurora"],
            message: nil
        )
        let records = [
            ToolResultRecord(toolName: "read_file", content: "Aurora MEETING-NOTES-754", errorKind: nil)
        ]
        XCTAssertTrue(AssertionEvaluator.evaluate(assertion, finalAnswer: "", toolResults: records).passed)
        XCTAssertFalse(AssertionEvaluator.evaluate(assertion, finalAnswer: "", toolResults: []).passed)
    }

    func test_toolResultErrorKindAssertion_requiresExpectedError() {
        let assertion = Scenario.Assertion(
            kind: "toolResultErrorKind",
            value: "sample_repo_search",
            values: ["cancelled"],
            message: nil
        )
        let records = [
            ToolResultRecord(toolName: "sample_repo_search", content: "cancelled by user", errorKind: "cancelled")
        ]
        XCTAssertTrue(AssertionEvaluator.evaluate(assertion, finalAnswer: "", toolResults: records).passed)
        XCTAssertFalse(AssertionEvaluator.evaluate(assertion, finalAnswer: "", toolResults: [
            ToolResultRecord(toolName: "sample_repo_search", content: "timeout", errorKind: "timeout")
        ]).passed)
    }

    func test_unknownAssertionKind_fails() {
        let assertion = Scenario.Assertion(kind: "fuzzy", value: "x", values: nil, message: nil)
        XCTAssertFalse(AssertionEvaluator.evaluate(assertion, finalAnswer: "x").passed)
    }

    // MARK: - ScenarioLoader

    func test_scenarioLoader_decodesAllBuiltIn() throws {
        let scenarios = try ScenarioLoader.loadBuiltIn()
        XCTAssertEqual(scenarios.count, 9, "expected nine built-in scenarios")
        let ids = scenarios.map(\.id).sorted()
        XCTAssertEqual(ids, [
            "01-now",
            "02-calc",
            "03-read",
            "04-list",
            "meeting-notes-summary",
            "oversize-tool-output",
            "parallel-readme-comparison",
            "shopping-list-budget",
            "structured-json-extraction",
        ])
        for s in scenarios {
            XCTAssertFalse(s.systemPrompt.isEmpty, "\(s.id) missing systemPrompt")
            XCTAssertFalse(s.assertions.isEmpty, "\(s.id) missing assertions")
            if s.requiredTools.isEmpty {
                XCTAssertEqual(s.id, "structured-json-extraction", "only structured JSON is currently tool-free")
            }
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
        let runner = makeRunner(backend: backend, registry: registry)
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
        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)
        XCTAssertTrue(outcome.passed)
    }

    func test_runner_executesMeetingNotesMultiTurnFilesystemScenario() async throws {
        let scenario = try builtInScenario("meeting-notes-summary")
        let registry = ToolRegistry(tools: [
            ListDirTool.makeExecutor(),
            ReadFileTool.makeExecutor()
        ])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "list_dir", arguments: #"{"dir":"notes"}"#),
            .toolCall(name: "read_file", arguments: #"{"path":"notes/standup.md"}"#),
            .tokens(["Aurora shipped the deterministic tool harness; Beacon is blocked on MCP credentials."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "answer=\(outcome.finalAnswer)")
        XCTAssertEqual(outcome.toolCallsExecuted, ["list_dir", "read_file"])
        XCTAssertTrue(
            outcome.toolResults.contains { $0.toolName == "read_file" && $0.content.contains("MEETING-NOTES-754") },
            "side-effect-free filesystem read should expose the seeded note nonce"
        )
    }

    func test_runner_executesShoppingListReadThenCalcScenario() async throws {
        let scenario = try builtInScenario("shopping-list-budget")
        let registry = ToolRegistry(tools: [
            ReadFileTool.makeExecutor(),
            CalcTool.makeExecutor()
        ])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "read_file", arguments: #"{"path":"shopping-list.txt"}"#),
            .toolCall(name: "calc", arguments: #"{"a":12.5,"op":"+","b":7.25}"#),
            .tokens(["apples and rice cost 19.75; skip saffron."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "answer=\(outcome.finalAnswer)")
        XCTAssertEqual(outcome.toolCallsExecuted, ["read_file", "calc"])
        XCTAssertTrue(outcome.toolResults.contains { $0.toolName == "calc" && $0.content.contains("19.75") })
    }

    func test_runner_executesParallelReadmeComparisonFromSameTurnToolCalls() async throws {
        let scenario = try builtInScenario("parallel-readme-comparison")
        let registry = ToolRegistry(tools: [ReadFileTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .mixed(tokens: [], toolCalls: [
                (name: "read_file", arguments: #"{"path":"readmes/backend-a.md"}"#),
                (name: "read_file", arguments: #"{"path":"readmes/backend-b.md"}"#)
            ]),
            .tokens(["DEMO-README-NONCE appears in both; Backend A uses streaming tools and Backend B uses batch tools."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "answer=\(outcome.finalAnswer)")
        XCTAssertEqual(outcome.toolCallsExecuted, ["read_file", "read_file"])
        XCTAssertEqual(outcome.toolResults.filter { $0.toolName == "read_file" }.count, 2)
        XCTAssertTrue(outcome.finalAnswer.contains("DEMO-README-NONCE"))
    }

    func test_runner_surfacesOversizeToolOutputPolicy() async throws {
        let scenario = Scenario(
            id: "test-oversize-output",
            description: "",
            systemPrompt: "sys",
            userPrompt: "read huge file",
            requiredTools: ["huge_fixture"],
            assertions: [
                Scenario.Assertion(kind: "toolInvoked", value: "huge_fixture", values: nil, message: nil),
                Scenario.Assertion(kind: "toolResultErrorKind", value: "huge_fixture", values: ["invalidArguments"], message: nil),
                Scenario.Assertion(kind: "containsAll", value: nil, values: ["exceeds maxBytes", "narrower"], message: nil)
            ],
            backend: Scenario.BackendSpec(kind: "mock", model: "scripted", fallbackModel: nil, temperature: 0, seed: nil, topK: nil)
        )
        let registry = ToolRegistry(tools: [
            FixedToolExecutor(name: "huge_fixture") { _ in
                ToolResult(callId: "", content: String(repeating: "x", count: 64), errorKind: nil)
            }
        ])
        registry.outputPolicy = ToolOutputPolicy(maxBytes: 16, onOversize: .rejectWithError)
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "huge_fixture", arguments: "{}"),
            .tokens(["The tool output exceeds maxBytes; request a narrower slice."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "assertions=\(outcome.assertions)")
        XCTAssertEqual(outcome.toolResults.first?.errorKind, "invalidArguments")
        XCTAssertTrue(outcome.toolResults.first?.content.contains("64 > 16") == true)
    }

    func test_runner_builtinOversizeScenarioTripsDefaultOutputPolicy() async throws {
        let scenario = try builtInScenario("oversize-tool-output")
        let registry = ToolRegistry(tools: [ReadFileTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "read_file", arguments: #"{"path":"oversize-output.txt"}"#),
            .tokens(["The read_file output exceeds maxBytes; ask for a narrower slice."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "default output policy should reject the oversize fixture")
        XCTAssertEqual(outcome.toolResults.first?.errorKind, "invalidArguments")
        XCTAssertTrue(outcome.toolResults.first?.content.contains("32768") == true)
    }


    func test_runner_recordsCancellationContractWithoutLeakingStaleOutput() async throws {
        let scenario = Scenario(
            id: "cancel-mid-search",
            description: "",
            systemPrompt: "sys",
            userPrompt: "search slowly",
            requiredTools: ["sample_repo_search"],
            // A `.cancelled` tool result unwinds the production dispatch loop
            // immediately (the orchestrator does not let the model narrate over
            // a cancelled tool), so the contract is verified through the
            // recorded tool result, not a follow-up text turn.
            assertions: [
                Scenario.Assertion(kind: "toolInvoked", value: "sample_repo_search", values: nil, message: nil),
                Scenario.Assertion(kind: "toolResultErrorKind", value: "sample_repo_search", values: ["cancelled"], message: nil),
                Scenario.Assertion(kind: "toolResultContains", value: "sample_repo_search", values: ["cancelled"], message: nil)
            ],
            backend: Scenario.BackendSpec(kind: "mock", model: "scripted", fallbackModel: nil, temperature: 0, seed: nil, topK: nil)
        )
        let registry = ToolRegistry(tools: [
            FixedToolExecutor(name: "sample_repo_search") { _ in
                ToolResult(callId: "", content: "cancelled by user", errorKind: .cancelled)
            }
        ])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "sample_repo_search", arguments: #"{"query":"needle"}"#),
            .tokens(["Search was cancelled by the user; no stale results were used."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "answer=\(outcome.finalAnswer)")
        XCTAssertFalse(outcome.finalAnswer.contains("FAKE_STALE_RESULT"))
    }

    func test_runner_recoversAfterTransientToolCrash() async throws {
        let scenario = Scenario(
            id: "crash-recovery",
            description: "",
            systemPrompt: "sys",
            userPrompt: "retry after crash",
            requiredTools: ["sample_repo_search"],
            assertions: [
                Scenario.Assertion(kind: "toolInvoked", value: "sample_repo_search", values: nil, message: nil),
                Scenario.Assertion(kind: "toolResultErrorKind", value: "sample_repo_search", values: ["transient"], message: nil),
                Scenario.Assertion(kind: "containsAll", value: nil, values: ["recovered", "CRASH-RECOVERY-754"], message: nil)
            ],
            backend: Scenario.BackendSpec(kind: "mock", model: "scripted", fallbackModel: nil, temperature: 0, seed: nil, topK: nil)
        )
        let crashingTool = SequencedToolExecutor(
            name: "sample_repo_search",
            results: [
                ToolResult(callId: "", content: "simulated worker crash", errorKind: .transient),
                ToolResult(callId: "", content: #"{"matches":[{"path":"recovery.md","snippet":"CRASH-RECOVERY-754"}]}"#, errorKind: nil)
            ]
        )
        let registry = ToolRegistry(tools: [crashingTool])
        // The retry varies its query. The production dispatch loop
        // short-circuits two *identical* consecutive tool calls (a safety
        // valve against loops), so a faithful recovery turn — like a real
        // model — issues a distinct query on the second attempt.
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "sample_repo_search", arguments: #"{"query":"crash"}"#),
            .toolCall(name: "sample_repo_search", arguments: #"{"query":"crash recovery"}"#),
            .tokens(["The search recovered and found CRASH-RECOVERY-754."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "answer=\(outcome.finalAnswer)")
        XCTAssertEqual(outcome.toolCallsExecuted, ["sample_repo_search", "sample_repo_search"])
        XCTAssertTrue(outcome.toolResults.contains { $0.errorKind == nil && $0.content.contains("CRASH-RECOVERY-754") })
    }

    func test_runner_executesAppIntentStyleToolAndRecordsSideEffect() async throws {
        let recorder = ReminderRecorder()
        let scenario = Scenario(
            id: "create-reminder",
            description: "",
            systemPrompt: "sys",
            userPrompt: "create reminder",
            requiredTools: ["create_reminder_intent"],
            assertions: [
                Scenario.Assertion(kind: "toolInvoked", value: "create_reminder_intent", values: nil, message: nil),
                Scenario.Assertion(kind: "toolResultContains", value: "create_reminder_intent", values: ["REMINDER-754"], message: nil),
                Scenario.Assertion(kind: "containsLiteral", value: "REMINDER-754", values: nil, message: nil)
            ],
            backend: Scenario.BackendSpec(kind: "mock", model: "scripted", fallbackModel: nil, temperature: 0, seed: nil, topK: nil)
        )
        let registry = ToolRegistry(tools: [
            FixedToolExecutor(name: "create_reminder_intent", requiresApproval: true) { _ in
                await recorder.record("REMINDER-754")
                return ToolResult(callId: "", content: #"{"created":true,"id":"REMINDER-754"}"#, errorKind: nil)
            }
        ])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "create_reminder_intent", arguments: #"{"title":"Wave 1 QA"}"#),
            .tokens(["Created reminder REMINDER-754."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "answer=\(outcome.finalAnswer)")
        let recordedReminders = await recorder.values()
        XCTAssertEqual(recordedReminders, ["REMINDER-754"])
    }

    func test_runner_passesStructuredJSONScenarioWithoutTools() async throws {
        let scenario = try builtInScenario("structured-json-extraction")
        let registry = ToolRegistry()
        let backend = ScriptedBackend(turns: [
            .tokens([#"{"invoice_id":"INV-754-CORE","total":123.45,"currency":"USD"}"#])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "answer=\(outcome.finalAnswer)")
        XCTAssertTrue(outcome.toolCallsExecuted.isEmpty)
        XCTAssertFalse(outcome.finalAnswer.contains("```"), "structured JSON scenario should not need markdown fences")
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
        let runner = makeRunner(backend: backend, registry: registry, maxIterations: 2)
        let outcome = try await runner.run(scenario)
        XCTAssertFalse(outcome.passed, "scenario should not pass once the runner aborts on iteration cap")
        XCTAssertEqual(outcome.toolCallsExecuted.count, 2, "should dispatch exactly maxIterations tool calls")
    }

    private func builtInScenario(_ id: String) throws -> Scenario {
        let scenarios = try ScenarioLoader.loadBuiltIn()
        return try XCTUnwrap(scenarios.first { $0.id == id }, "missing built-in scenario \(id)")
    }

    // MARK: - TranscriptLogger

    func test_transcriptLogger_writesOneJsonlRowPerEvent() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("ManifoldToolsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("manifold-tools-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: directory)
        }

        let logger = try TranscriptLogger(url: path)
        logger.append(.prompt(scenarioId: "t", system: "sys", user: "u", requiredTools: ["now"]))
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

    func test_transcriptLogger_stampsBackendModelQuantOnEveryRecord() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("ManifoldToolsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("attributed-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: directory)
        }

        let logger = try TranscriptLogger(url: path, backend: "ollama", model: "qwen3.5-9b", quant: "q4_K_M")
        logger.append(.prompt(scenarioId: "t", system: "sys", user: "u", requiredTools: ["now"]))
        logger.append(.toolCall(scenarioId: "t", name: "now", arguments: "{}"))
        logger.append(.assertion(scenarioId: "t", passed: true, message: "ok"))

        let data = try Data(contentsOf: path)
        let lines = data.split(separator: 0x0A).map { Data($0) }
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
            XCTAssertEqual(object["backend"] as? String, "ollama", "every record must be attributable to its backend")
            XCTAssertEqual(object["model"] as? String, "qwen3.5-9b", "every record must carry its model")
            XCTAssertEqual(object["quant"] as? String, "q4_K_M", "every record must carry its quant when present")
        }
    }

    func test_transcriptLogger_omitsQuantWhenNil_andKeepsRecordShapeBackwardCompatible() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("ManifoldToolsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("no-quant-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: directory)
        }

        // No attribution at all → original record shape, backward compatible.
        let bare = try TranscriptLogger(url: path)
        bare.append(.final(scenarioId: "t", text: "done"))
        let bareData = try Data(contentsOf: path)
        let firstLine = try XCTUnwrap(bareData.split(separator: UInt8(0x0A)).first.map { Data($0) })
        let bareObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: firstLine) as? [String: Any]
        )
        XCTAssertNil(bareObject["backend"], "no attribution → no backend key")
        XCTAssertNil(bareObject["model"])
        XCTAssertNil(bareObject["quant"])
        XCTAssertEqual(bareObject["kind"] as? String, "final", "existing field names must be unchanged")
    }

    // MARK: - ConformanceScorer

    /// Builds a fixture transcript covering an all-pass, a partial, and an
    /// errored scenario across two models, then scores it.
    func test_conformanceScorer_producesRowsAndVerdictsFromTranscript() throws {
        let lines = [
            // all-pass: 2 passing assertions, 1 tool call, model A
            #"{"kind":"prompt","scenario":"s1","backend":"ollama","model":"A","quant":"q4_K_M"}"#,
            #"{"kind":"tool_call","scenario":"s1","backend":"ollama","model":"A","quant":"q4_K_M","name":"now"}"#,
            #"{"kind":"assertion","scenario":"s1","backend":"ollama","model":"A","quant":"q4_K_M","passed":true}"#,
            #"{"kind":"assertion","scenario":"s1","backend":"ollama","model":"A","quant":"q4_K_M","passed":true}"#,
            // partial: 1 pass, 1 fail, model A
            #"{"kind":"assertion","scenario":"s2","backend":"ollama","model":"A","quant":"q4_K_M","passed":true}"#,
            #"{"kind":"assertion","scenario":"s2","backend":"ollama","model":"A","quant":"q4_K_M","passed":false}"#,
            // errored: explicit error record, model B
            #"{"kind":"prompt","scenario":"s3","backend":"ollama","model":"B"}"#,
            #"{"kind":"error","scenario":"s3","backend":"ollama","model":"B"}"#,
            // a torn / malformed final line must be skipped, not fatal
            #"{"kind":"assertion","scenario":"s3","backend":"oll"#
        ].joined(separator: "\n")

        let rows = ConformanceScorer.score(jsonl: lines)
        XCTAssertEqual(rows.count, 3, "one row per (backend, model, quant, scenario)")

        let s1 = try XCTUnwrap(rows.first { $0.scenario == "s1" })
        XCTAssertEqual(s1.model, "A")
        XCTAssertEqual(s1.quant, "q4_K_M")
        XCTAssertEqual(s1.assertionsPassed, 2)
        XCTAssertEqual(s1.assertionsFailed, 0)
        XCTAssertEqual(s1.toolCallCount, 1)
        XCTAssertFalse(s1.errored)
        XCTAssertEqual(s1.verdict, .pass)

        let s2 = try XCTUnwrap(rows.first { $0.scenario == "s2" })
        XCTAssertEqual(s2.assertionsPassed, 1)
        XCTAssertEqual(s2.assertionsFailed, 1)
        XCTAssertEqual(s2.verdict, .partial)

        let s3 = try XCTUnwrap(rows.first { $0.scenario == "s3" })
        XCTAssertEqual(s3.model, "B")
        XCTAssertNil(s3.quant)
        XCTAssertTrue(s3.errored)
        XCTAssertEqual(s3.verdict, .errored)
    }

    func test_conformanceScorer_failVerdictWhenNoAssertionsPass() {
        let line = #"{"kind":"assertion","scenario":"s","backend":"mock","model":"m","passed":false}"#
        let rows = ConformanceScorer.score(jsonl: line)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.verdict, .fail)
    }

    func test_conformanceScorer_roundTripsThroughJSON() throws {
        let line = #"{"kind":"assertion","scenario":"s","backend":"ollama","model":"A","quant":"q8_0","passed":true}"#
        let rows = ConformanceScorer.score(jsonl: line)
        let data = try ConformanceScorer.encodeJSON(rows)
        let decoded = try JSONDecoder().decode([ConformanceScorer.ResultRow].self, from: data)
        XCTAssertEqual(decoded, rows, "rows must survive a JSON round-trip")
    }

    /// Tool-selection ConfusionCounts must match the shared core metric: a
    /// scenario requiring `now` where the model calls `now` plus a decoy
    /// `weather` is tp=1 / fp=1 / fn=0; a scenario requiring `calc` where the
    /// model calls nothing is tp=0 / fp=0 / fn=1.
    func test_conformanceScorer_computesToolSelectionConfusionAndMacroAverage() {
        let lines = [
            #"{"kind":"prompt","scenario":"s1","backend":"ollama","model":"A","requiredTools":["now"]}"#,
            #"{"kind":"tool_call","scenario":"s1","backend":"ollama","model":"A","name":"now"}"#,
            #"{"kind":"tool_call","scenario":"s1","backend":"ollama","model":"A","name":"weather"}"#,
            #"{"kind":"prompt","scenario":"s2","backend":"ollama","model":"A","requiredTools":["calc"]}"#,
            // no tool_call for s2 → a missed required tool (false negative)
            // s3 is a no-tool scenario: empty requiredTools, excluded from macro avg
            #"{"kind":"prompt","scenario":"s3","backend":"ollama","model":"A","requiredTools":[]}"#,
            #"{"kind":"final","scenario":"s3","backend":"ollama","model":"A","text":"hello"}"#
        ].joined(separator: "\n")

        let rows = ConformanceScorer.score(jsonl: lines)

        let s1 = rows.first { $0.scenario == "s1" }
        XCTAssertEqual(s1?.toolTP, 1)
        XCTAssertEqual(s1?.toolFP, 1, "the decoy `weather` call is a false positive")
        XCTAssertEqual(s1?.toolFN, 0)
        XCTAssertEqual(s1?.calledTools, ["now", "weather"], "called tools are sorted + de-duped")
        XCTAssertEqual(s1?.confusion.precision ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(s1?.confusion.recall ?? 0, 1.0, accuracy: 0.0001)

        let s2 = rows.first { $0.scenario == "s2" }
        XCTAssertEqual(s2?.toolTP, 0)
        XCTAssertEqual(s2?.toolFP, 0)
        XCTAssertEqual(s2?.toolFN, 1, "required `calc` never called → false negative")

        let s3 = rows.first { $0.scenario == "s3" }
        XCTAssertFalse(s3?.isToolBearing ?? true, "empty requiredTools → not tool-bearing")

        // Macro average is over the two tool-bearing rows only (s3 excluded):
        // precision = mean(0.5, 0.0) = 0.25; recall = mean(1.0, 0.0) = 0.5.
        let macro = ConformanceScorer.aggregate(rows)
        XCTAssertEqual(macro.precision, 0.25, accuracy: 0.0001)
        XCTAssertEqual(macro.recall, 0.5, accuracy: 0.0001)
    }
}

private struct FixedToolExecutor: ToolExecutor {
    let definition: ToolDefinition
    let supportsConcurrentDispatch: Bool
    let requiresApproval: Bool
    private let handler: @Sendable (JSONSchemaValue) async throws -> ToolResult

    init(
        name: String,
        supportsConcurrentDispatch: Bool = true,
        requiresApproval: Bool = false,
        handler: @escaping @Sendable (JSONSchemaValue) async throws -> ToolResult
    ) {
        self.definition = ToolDefinition(
            name: name,
            description: "Test fixture tool \(name)",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ])
        )
        self.supportsConcurrentDispatch = supportsConcurrentDispatch
        self.requiresApproval = requiresApproval
        self.handler = handler
    }

    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        try await handler(arguments)
    }
}

private final class SequencedToolExecutor: ToolExecutor, @unchecked Sendable {
    let definition: ToolDefinition
    let supportsConcurrentDispatch = false
    let requiresApproval = false

    private var results: [ToolResult]
    private var cursor = 0

    init(name: String, results: [ToolResult]) {
        self.definition = ToolDefinition(
            name: name,
            description: "Sequenced test fixture tool \(name)",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ])
        )
        self.results = results
    }

    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        guard cursor < results.count else {
            return results.last ?? ToolResult(callId: "", content: "", errorKind: nil)
        }
        let result = results[cursor]
        cursor += 1
        return result
    }
}

private actor ReminderRecorder {
    private var recorded: [String] = []

    func record(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }
}
