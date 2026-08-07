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

    func test_toolNotInvokedAssertion_namedForm_passesWhenToolWithheld() {
        let assertion = Scenario.Assertion(kind: "toolNotInvoked", value: "decoy_tool", values: nil, message: nil)
        XCTAssertTrue(
            AssertionEvaluator.evaluate(assertion, finalAnswer: "anything", toolsInvoked: ["now"]).passed,
            "toolNotInvoked should pass when the named tool never appears in toolsInvoked"
        )
    }

    /// The test that matters: a no-op evaluator (or one that ignores
    /// `toolsInvoked`) would pass this too — the assertion must actually go
    /// red when the forbidden tool WAS dispatched, which is the whole reason
    /// this assertion kind exists (catching a decoy call under a distractor
    /// sweep).
    func test_toolNotInvokedAssertion_namedForm_failsWhenToolWasInvoked() {
        let assertion = Scenario.Assertion(kind: "toolNotInvoked", value: "decoy_tool", values: nil, message: nil)
        let outcome = AssertionEvaluator.evaluate(
            assertion,
            finalAnswer: "anything",
            toolsInvoked: ["now", "decoy_tool"]
        )
        XCTAssertFalse(outcome.passed, "toolNotInvoked must fail when the forbidden tool was dispatched")
        XCTAssertTrue(outcome.message.contains("should have been withheld"))
    }

    func test_toolNotInvokedAssertion_unnamedForm_passesOnTotalAbstention() {
        let assertion = Scenario.Assertion(kind: "toolNotInvoked", value: nil, values: nil, message: nil)
        XCTAssertTrue(
            AssertionEvaluator.evaluate(assertion, finalAnswer: "a direct answer", toolsInvoked: []).passed,
            "value-omitted toolNotInvoked should pass when zero tools were dispatched"
        )
    }

    /// Sabotage check for the unnamed (abstention) form: if the evaluator
    /// ignored `toolsInvoked` entirely (a no-op that always passes), this
    /// would stay green. It must go red the moment ANY tool — including one
    /// never named by the scenario, i.e. a decoy — was dispatched.
    func test_toolNotInvokedAssertion_unnamedForm_failsWhenAnyToolWasInvoked() {
        let assertion = Scenario.Assertion(kind: "toolNotInvoked", value: nil, values: nil, message: nil)
        let outcome = AssertionEvaluator.evaluate(
            assertion,
            finalAnswer: "a direct answer",
            toolsInvoked: ["some_unrelated_decoy"]
        )
        XCTAssertFalse(outcome.passed, "value-omitted toolNotInvoked must fail when any tool was dispatched")
        XCTAssertTrue(outcome.message.contains("expected total abstention"))
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
        XCTAssertEqual(scenarios.count, 12, "expected twelve built-in scenarios")
        let ids = scenarios.map(\.id).sorted()
        XCTAssertEqual(ids, [
            "01-now",
            "02-calc",
            "03-read",
            "04-list",
            "abstention-definition",
            "handoff-note-lookup",
            "meeting-notes-summary",
            "oversize-tool-output",
            "parallel-readme-comparison",
            "schema-beats-prose-resistance",
            "shopping-list-budget",
            "structured-json-extraction",
        ])
        let toolFreeIds: Set<String> = ["structured-json-extraction", "abstention-definition"]
        for s in scenarios {
            XCTAssertFalse(s.systemPrompt.isEmpty, "\(s.id) missing systemPrompt")
            XCTAssertFalse(s.assertions.isEmpty, "\(s.id) missing assertions")
            if s.requiredTools.isEmpty {
                XCTAssertTrue(toolFreeIds.contains(s.id), "\(s.id) unexpectedly tool-free")
            }
        }
    }

    /// Honesty-gate coverage for the three new decoy-degradation scenarios
    /// specifically (see `Scenario.Assertion.kind` doc comment on
    /// `toolInvoked`/`toolNotInvoked`) — every one of them must be able to
    /// catch a hallucinated final answer, not just a plausible one.
    func test_newDecoyDegradationScenarios_carryHonestyGateAssertion() throws {
        let scenarios = try ScenarioLoader.loadBuiltIn()
        for id in ["abstention-definition", "schema-beats-prose-resistance", "handoff-note-lookup"] {
            let scenario = try XCTUnwrap(scenarios.first { $0.id == id })
            XCTAssertTrue(
                scenario.assertions.contains { $0.kind == "toolInvoked" || $0.kind == "toolNotInvoked" },
                "\(id) has no toolInvoked/toolNotInvoked honesty-gate assertion"
            )
        }
    }

    /// `loadBuiltIn()` resolves the corpus from `Bundle.module`, not a path
    /// relative to the process working directory. Temporarily chdir to a
    /// directory that has no `Sources/ManifoldTools/Scenarios/built-in` tree;
    /// the loader must still find the full corpus via the resource bundle.
    /// This is the regression guard for the CWD-relative loader that forced
    /// companion packages to vendor drift-prone copies.
    func test_scenarioLoader_loadsFromBundleRegardlessOfWorkingDirectory() throws {
        let fm = FileManager.default
        let originalCWD = fm.currentDirectoryPath
        let foreignCWD = NSTemporaryDirectory()  // has no package source tree

        guard fm.changeCurrentDirectoryPath(foreignCWD) else {
            throw XCTSkip("could not chdir to a scratch directory for the bundle-resolution check")
        }
        defer { _ = fm.changeCurrentDirectoryPath(originalCWD) }

        // Sanity: the legacy CWD-relative path genuinely does not exist here,
        // so a pass below can only come from the bundle.
        let legacyRelative = URL(fileURLWithPath: foreignCWD)
            .appendingPathComponent("Sources/ManifoldTools/Scenarios/built-in", isDirectory: true)
        XCTAssertFalse(
            fm.fileExists(atPath: legacyRelative.path),
            "test precondition: the foreign CWD must not contain the package source tree"
        )

        let scenarios = try ScenarioLoader.loadBuiltIn()
        XCTAssertEqual(scenarios.count, 12, "full corpus must load from Bundle.module under a foreign CWD")
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

    // MARK: - Decoy-degradation scenarios (abstention / schema-vs-prose resistance / output-fed argument)

    func test_runner_abstentionScenario_passesOnTrueAbstention() async throws {
        let scenario = try builtInScenario("abstention-definition")
        // Register the whole reference toolset so we're exercising the real
        // "requiredTools: [] advertises everything" path the decoy sweep
        // depends on, not an empty-registry vacuous pass.
        let registry = ToolRegistry(tools: [NowTool.makeExecutor(), CalcTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .tokens(["Ubiquitous means present or found everywhere at once."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "answer=\(outcome.finalAnswer)")
        XCTAssertTrue(outcome.toolCallsExecuted.isEmpty)
    }

    /// The test that matters for this scenario: a model that reaches for a
    /// tool it was never asked about (the exact decoy-precision failure the
    /// scenario exists to catch) must fail, not silently pass because the
    /// final-answer text still happens to look right.
    func test_runner_abstentionScenario_failsWhenModelCallsUnnecessaryTool() async throws {
        let scenario = try builtInScenario("abstention-definition")
        let registry = ToolRegistry(tools: [NowTool.makeExecutor(), CalcTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "now", arguments: "{}"),
            .tokens(["Ubiquitous means present or found everywhere at once."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertFalse(outcome.passed, "an unnecessary tool call must fail the abstention scenario")
        XCTAssertEqual(outcome.toolCallsExecuted, ["now"])
    }

    /// Reframed 2026-08-07 after live validation (#2450): the scenario no
    /// longer tries to provoke a hallucinated call — neither llama3.1:8b nor
    /// qwen3.5:9b ever attempted the nudged name, both deferred to the real
    /// schema. It now measures that resistance directly via `toolNotInvoked`.
    func test_runner_schemaBeatsProse_passesWhenModelResistsTheNudge() async throws {
        let scenario = try builtInScenario("schema-beats-prose-resistance")
        // Only `now` is registered — `get_current_date` (what the system
        // prompt nudges toward) has no executor at all.
        let registry = ToolRegistry(tools: [NowTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "now", arguments: "{}"),
            .tokens([NowTool.defaultFixture])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "answer=\(outcome.finalAnswer)")
        XCTAssertEqual(outcome.toolCallsExecuted, ["now"])
    }

    /// The test that matters: a model that DOES take the bait and calls the
    /// nudged, never-registered name must fail — proves `toolNotInvoked` is
    /// load-bearing here, not decorative. The dispatch loop still rejects the
    /// call cleanly (an `unknownTool` result, not a crash), but that clean
    /// rejection is no longer sufficient to pass — taking the bait at all is
    /// the failure this scenario now measures.
    func test_runner_schemaBeatsProse_failsWhenModelTakesTheBait() async throws {
        let scenario = try builtInScenario("schema-beats-prose-resistance")
        let registry = ToolRegistry(tools: [NowTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "get_current_date", arguments: "{}"),
            .toolCall(name: "now", arguments: "{}"),
            .tokens([NowTool.defaultFixture])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertFalse(outcome.passed, "taking the bait must fail the scenario even though now was also called")
        XCTAssertTrue(
            outcome.toolResults.contains { $0.toolName == "get_current_date" && $0.errorKind == "unknownTool" },
            "the dispatch loop must still reject the nudged name cleanly, even though doing so no longer saves the scenario"
        )
    }

    func test_runner_handoffNoteLookup_argumentComesFromListDirOutput() async throws {
        let scenario = try builtInScenario("handoff-note-lookup")
        let registry = ToolRegistry(tools: [ListDirTool.makeExecutor(), ReadFileTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "list_dir", arguments: #"{"dir":"handoff"}"#),
            .toolCall(name: "read_file", arguments: #"{"path":"handoff/note-7f3a91.md"}"#),
            .tokens(["The handoff code is HANDOFF-CODE-93217."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "answer=\(outcome.finalAnswer)")
        XCTAssertEqual(outcome.toolCallsExecuted, ["list_dir", "read_file"])
        XCTAssertTrue(
            outcome.toolResults.contains { $0.toolName == "list_dir" && $0.content.contains("note-7f3a91.md") },
            "list_dir result should reveal the un-guessable filename"
        )
        XCTAssertTrue(
            outcome.toolResults.contains { $0.toolName == "read_file" && $0.content.contains("HANDOFF-CODE-93217") },
            "read_file's argument must have matched the discovered filename to recover the nonce"
        )
    }

    /// The test that proves the chain is load-bearing: a model that skips
    /// `list_dir` and guesses a plausible filename directly cannot recover
    /// the nonce — `read_file` reports `notFound` and the final answer never
    /// contains the seeded code, so both `toolResultContains` assertions and
    /// the final `containsLiteral` fail. Without this the scenario would be
    /// no different from `meeting-notes-summary`, where the guessed filename
    /// happens to work.
    func test_runner_handoffNoteLookup_failsWhenModelSkipsListDirAndGuesses() async throws {
        let scenario = try builtInScenario("handoff-note-lookup")
        let registry = ToolRegistry(tools: [ListDirTool.makeExecutor(), ReadFileTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "read_file", arguments: #"{"path":"handoff/note.md"}"#),
            .tokens(["I couldn't find the handoff code."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertFalse(outcome.passed, "a guessed filename must not be able to recover the seeded nonce")
        XCTAssertFalse(outcome.toolCallsExecuted.contains("list_dir"))
        XCTAssertTrue(
            outcome.toolResults.contains { $0.toolName == "read_file" && $0.errorKind == "notFound" },
            "the guessed filename should not exist in the sandbox"
        )
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
                // The transient failure is recovered *internally* by the dispatch
                // loop's bounded retry, so only the SUCCESS result is surfaced.
                // `toolResultErrorKind` can't express the nil-success case, so the
                // "no transient surfaced" contract is asserted via XCTAssert below;
                // here we only assert the recovered answer reaches the model.
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
        // Auto-retry recovers transparently: the model issues a SINGLE tool call,
        // the executor's first attempt returns `.transient`, and the dispatch
        // loop retries the identical call with backoff. The retry consumes the
        // executor's success result, which is the only `.toolResult` surfaced to
        // the model — the transient attempt is swallowed internally. The model
        // therefore never sees the failure and goes straight to its final answer.
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "sample_repo_search", arguments: #"{"query":"crash"}"#),
            .tokens(["The search recovered and found CRASH-RECOVERY-754."])
        ])

        let outcome = try await makeRunner(backend: backend, registry: registry).run(scenario)

        XCTAssertTrue(outcome.passed, "answer=\(outcome.finalAnswer)")
        // One model-emitted tool call; the internal retry is NOT a separate
        // recorded call (the loop surfaces one `.toolCall` per model emission).
        XCTAssertEqual(outcome.toolCallsExecuted, ["sample_repo_search"])
        // Exactly one tool result surfaces, and it is the recovered SUCCESS —
        // proving the transient was retried away internally rather than shown
        // to the model.
        XCTAssertEqual(outcome.toolResults.count, 1)
        XCTAssertTrue(outcome.toolResults.contains { $0.errorKind == nil && $0.content.contains("CRASH-RECOVERY-754") })
        // `ToolResultRecord.errorKind` is the raw-value string (nil for success).
        let surfacedTransient = outcome.toolResults.contains { $0.errorKind == "transient" }
        XCTAssertFalse(
            surfacedTransient,
            "the transient attempt must be recovered internally, never surfaced"
        )
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

    // MARK: - GenerationConfig wiring (2026-07 inert-code audit, finding #25)

    /// `Scenario.BackendSpec.seed` must reach `GenerationConfig.seed` — it was
    /// previously decoded and silently dropped by `ScenarioRunner`.
    func test_runner_threadsScenarioSeedIntoGenerationConfig() async throws {
        let registry = ToolRegistry(tools: [NowTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "now", arguments: "{}"),
            .tokens([NowTool.defaultFixture])
        ])
        let scenario = Scenario(
            id: "test-seed",
            description: "",
            systemPrompt: "sys",
            userPrompt: "what time is it?",
            requiredTools: ["now"],
            assertions: [
                Scenario.Assertion(kind: "containsLiteral", value: NowTool.defaultFixture, values: nil, message: nil)
            ],
            backend: Scenario.BackendSpec(kind: "mock", model: "scripted", fallbackModel: nil, temperature: 0, seed: 42, topK: nil)
        )
        _ = try await makeRunner(backend: backend, registry: registry).run(scenario)
        XCTAssertEqual(backend.receivedConfigs.first?.seed, 42, "scenario.backend.seed must reach GenerationConfig.seed")
    }

    /// A scenario with no `seed` must leave `GenerationConfig.seed` nil rather
    /// than substituting a default — nil is the documented "let the backend
    /// pick" signal.
    func test_runner_leavesGenerationConfigSeedNilWhenScenarioOmitsIt() async throws {
        let registry = ToolRegistry(tools: [NowTool.makeExecutor()])
        let backend = ScriptedBackend(turns: [
            .toolCall(name: "now", arguments: "{}"),
            .tokens([NowTool.defaultFixture])
        ])
        let scenario = Scenario(
            id: "test-no-seed",
            description: "",
            systemPrompt: "sys",
            userPrompt: "what time is it?",
            requiredTools: ["now"],
            assertions: [
                Scenario.Assertion(kind: "containsLiteral", value: NowTool.defaultFixture, values: nil, message: nil)
            ],
            backend: Scenario.BackendSpec(kind: "mock", model: "scripted", fallbackModel: nil, temperature: 0, seed: nil, topK: nil)
        )
        _ = try await makeRunner(backend: backend, registry: registry).run(scenario)
        XCTAssertNil(backend.receivedConfigs.first?.seed)
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

    /// `--repeat-index` (`ScenarioCLIHarness.Options.repeatIndex`) must reach
    /// every transcript record exactly like `backend`/`model`/`quant` — this
    /// is the whole mechanism `ConformanceScorer` later reads back to settle
    /// `ConformanceRecord.repeatIndex` instead of hardcoding `0`.
    func test_transcriptLogger_stampsRepeatIndexOnEveryRecord() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("ManifoldToolsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("repeat-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: directory)
        }

        let logger = try TranscriptLogger(url: path, backend: "ollama", model: "m", quant: nil, repeatIndex: 2)
        logger.append(.prompt(scenarioId: "t", system: "sys", user: "u", requiredTools: ["now"]))
        logger.append(.final(scenarioId: "t", text: "done"))

        let data = try Data(contentsOf: path)
        let lines = data.split(separator: 0x0A).map { Data($0) }
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
            XCTAssertEqual(object["repeatIndex"] as? Int, 2, "every record must carry its repeat index when set")
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
        XCTAssertNil(bareObject["repeatIndex"], "no --repeat-index → no repeatIndex key")
        XCTAssertEqual(bareObject["kind"] as? String, "final", "existing field names must be unchanged")
    }

    /// #2088: re-running to an existing `--output` path must TRUNCATE by default,
    /// never append a second run onto the first (which corrupts downstream scoring).
    func test_transcriptLogger_truncatesExistingOutputByDefault() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("ManifoldToolsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("rerun-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: directory)
        }

        // First run writes three events. Scoped so its handle closes before re-open.
        do {
            let firstRun = try TranscriptLogger(url: path)
            firstRun.append(.prompt(scenarioId: "s", system: "sys", user: "u", requiredTools: ["now"]))
            firstRun.append(.toolCall(scenarioId: "s", name: "now", arguments: "{}"))
            firstRun.append(.final(scenarioId: "s", text: "run one"))
        }

        // Re-run to the SAME path with the default (truncate) — the prior run must
        // be gone, not concatenated.
        do {
            let secondRun = try TranscriptLogger(url: path)
            secondRun.append(.final(scenarioId: "s", text: "run two"))
        }

        let text = try String(contentsOf: path, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 1, "default --output must truncate: only the second run's single event remains")
        XCTAssertTrue(text.contains("run two"), "the re-run's event must be present")
        XCTAssertFalse(text.contains("run one"), "the prior run's events must be truncated away, not appended to")
    }

    /// The opt-in `append: true` path preserves a prior transcript — the escape
    /// hatch that keeps the CLI's interleaved (scenario × model) runs in one file.
    func test_transcriptLogger_appendPreservesPriorContent() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("ManifoldToolsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("append-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: directory)
        }

        do {
            let firstRun = try TranscriptLogger(url: path)
            firstRun.append(.final(scenarioId: "s", text: "run one"))
        }
        do {
            let secondRun = try TranscriptLogger(url: path, append: true)
            secondRun.append(.final(scenarioId: "s", text: "run two"))
        }

        let text = try String(contentsOf: path, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 2, "append: true must keep the prior run and add the new one")
        XCTAssertTrue(text.contains("run one") && text.contains("run two"))
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

    // MARK: - #2005: expected-tool recovery for transcripts without `requiredTools`

    /// Regression for #2005. The manifold-llama soak emitter predates the
    /// `requiredTools` prompt field, so its `prompt` records carry no expected
    /// tool set. Before the fix, every correctly dispatched llama tool call was
    /// scored against an empty expected set → `toolTP=0, toolFP=1, f1=0` even
    /// though the right tool was called and the scenario verdict was `.pass`.
    ///
    /// This fixture reproduces the exact llama `tool_call`/`assertion` record
    /// shape (no `backend`/`model`/`quant`, no `requiredTools`; the required tool
    /// is named only in the back-ticked dispatch-requirement assertion). The
    /// scorer must recover `now` as the expected tool and credit it as a TP.
    func test_conformanceScorer_recoversExpectedToolFromAssertion_whenRequiredToolsAbsent() {
        let lines = [
            #"{"kind":"prompt","scenario":"01-now","system":"You have tools.","user":"What time is it?"}"#,
            #"{"kind":"tool_call","scenario":"01-now","name":"now","arguments":"{}"}"#,
            #"{"kind":"tool_result","scenario":"01-now","name":"now","content":"{}","errorKind":null}"#,
            #"{"kind":"assertion","scenario":"01-now","passed":true,"message":"Scenario requires `now` to actually be dispatched — dispatched"}"#,
            #"{"kind":"assertion","scenario":"01-now","passed":true,"message":"Final answer should quote the OOD timestamp from `now` — found"}"#
        ].joined(separator: "\n")

        let row = ConformanceScorer.score(jsonl: lines).first { $0.scenario == "01-now" }

        XCTAssertEqual(row?.expectedTools, ["now"], "required `now` recovered from the dispatch assertion")
        XCTAssertEqual(row?.calledTools, ["now"])
        XCTAssertEqual(row?.toolTP, 1, "a correctly dispatched expected tool is a true positive, not an FP (#2005)")
        XCTAssertEqual(row?.toolFP, 0)
        XCTAssertEqual(row?.toolFN, 0)
        XCTAssertEqual(row?.confusion.precision ?? 0, 1.0, accuracy: 0.0001, "precision must be > 0 for the recovered cell")
        XCTAssertEqual(row?.confusion.f1 ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(row?.verdict, .pass)
        XCTAssertTrue(row?.isToolBearing ?? false, "the recovered expected set makes the row tool-bearing")
    }

    /// Guard: recovery must not loosen matching into false positives. A scenario
    /// that requires `calc` but where the model called the wrong tool (`read_file`)
    /// must still score `calc` as a false negative and `read_file` as a false
    /// positive — never a spurious true positive. (Mirrors `shopping-list-budget`
    /// from the captured llama transcript.)
    func test_conformanceScorer_recoveredExpectedTool_stillScoresWrongToolAsFalsePositive() {
        let lines = [
            #"{"kind":"prompt","scenario":"shopping-list-budget","system":"You have tools.","user":"Total the cheapest items."}"#,
            #"{"kind":"tool_call","scenario":"shopping-list-budget","name":"read_file","arguments":"{}"}"#,
            #"{"kind":"assertion","scenario":"shopping-list-budget","passed":false,"message":"Scenario requires `calc` for the selected total — never dispatched — final answer may be hallucinated"}"#
        ].joined(separator: "\n")

        let row = ConformanceScorer.score(jsonl: lines).first { $0.scenario == "shopping-list-budget" }

        XCTAssertEqual(row?.expectedTools, ["calc"], "expected `calc` recovered even though it was never dispatched")
        XCTAssertEqual(row?.calledTools, ["read_file"])
        XCTAssertEqual(row?.toolTP, 0, "the wrong tool must NOT count as a true positive")
        XCTAssertEqual(row?.toolFP, 1, "the wrong tool (`read_file`) is a false positive")
        XCTAssertEqual(row?.toolFN, 1, "the required `calc` is a false negative")
    }

    /// Recovery is a fallback only. When the prompt record carries an explicit
    /// `requiredTools` (the Ollama / current-logger shape), the scorer must use it
    /// verbatim and never consult the assertion text — so an authoritative empty
    /// set stays a no-tool row even if an assertion happens to name a tool.
    func test_conformanceScorer_explicitRequiredToolsTakesPrecedenceOverAssertionRecovery() {
        let lines = [
            #"{"kind":"prompt","scenario":"s","backend":"ollama","model":"A","requiredTools":[]}"#,
            #"{"kind":"final","scenario":"s","backend":"ollama","model":"A","text":"hello"}"#,
            #"{"kind":"assertion","scenario":"s","backend":"ollama","model":"A","passed":true,"message":"Scenario requires `now` to actually be dispatched — dispatched"}"#
        ].joined(separator: "\n")

        let row = ConformanceScorer.score(jsonl: lines).first { $0.scenario == "s" }

        XCTAssertEqual(row?.expectedTools, [], "explicit empty requiredTools wins over assertion recovery")
        XCTAssertFalse(row?.isToolBearing ?? true, "an authoritative no-tool scenario stays non-tool-bearing")
    }

    /// The extractor must ignore free-prose requirement assertions (no back-ticked
    /// tool token) rather than crediting a phantom expected tool.
    func test_expectedToolsFromAssertion_ignoresProseAndExtractsBacktickedTools() {
        XCTAssertEqual(
            ConformanceScorer.expectedToolsFromAssertion("Scenario requires `read_file` to inspect standup.md — never dispatched — final answer may be hallucinated"),
            ["read_file"]
        )
        XCTAssertEqual(
            ConformanceScorer.expectedToolsFromAssertion("Scenario requires the shopping list to be read from the fixture — dispatched"),
            [],
            "free prose with no back-ticked tool token yields nothing"
        )
        XCTAssertEqual(
            ConformanceScorer.expectedToolsFromAssertion("Final answer should quote the calc result 320743 — found"),
            [],
            "only `Scenario requires …` requirement assertions are mined"
        )
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
