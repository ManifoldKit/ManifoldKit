#if Ollama && Tools
import XCTest
import ManifoldInference
import ManifoldTools
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// True end-to-end coverage of the #754 demo scenario matrix against a real
/// local Ollama server.
///
/// Local-only: `XCTSkipUnless(HardwareRequirements.hasOllamaServer)` and the
/// preferred-model gate match the pattern in `OllamaToolCallingE2ETests`.
/// Not run in CI.
///
/// Assertion strategy is intentionally semantic rather than prose-exact: each
/// scenario verifies the exact tool sequence, argument shape or side effect,
/// and that the final answer reflects the tool output.
///
/// `OLLAMA_TEST_MODEL` env var can pin a specific model; when set but the
/// model is not installed the test fails loudly rather than silently
/// falling back, so misconfigured local environments are visible.
@MainActor
final class DemoScenarioOllamaE2ETests: XCTestCase {

    private var backend: OllamaBackend!
    private var modelName: String!
    private var sandboxRoot: URL!
    private var harness: DemoScenarioE2EHarness!

    /// Models that reliably tool-call on Ollama. Picks the first one
    /// available in the local Ollama install.
    private static let preferredModels: [String] = [
        "llama3.1:8b",
        "qwen2.5:7b-instruct",
        "qwen2.5:7b",
    ]

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            HardwareRequirements.hasOllamaServer,
            "Ollama server not running at localhost:11434"
        )

        let available = HardwareRequirements.listOllamaModels() ?? []

        if let pinned = ProcessInfo.processInfo.environment["OLLAMA_TEST_MODEL"] {
            // Fail-loud on misconfigured pin so the failure mode isn't a
            // silent fallback to a non-tool-calling model.
            guard available.contains(pinned) else {
                XCTFail(
                    "OLLAMA_TEST_MODEL=\(pinned) is set but not installed locally. Installed: \(available)"
                )
                throw XCTSkip("OLLAMA_TEST_MODEL not installed")
            }
            modelName = pinned
        } else {
            guard let match = Self.preferredModels.first(where: { available.contains($0) }) else {
                throw XCTSkip(
                    "No tool-calling-capable Ollama model installed; need one of \(Self.preferredModels). Installed: \(available)"
                )
            }
            modelName = match
        }

        backend = OllamaBackend()
        backend.configure(
            baseURL: URL(string: "http://localhost:11434")!,
            modelName: modelName
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        // Per-test sandbox so the journal-write scenario doesn't trip on
        // residue from a previous run.
        sandboxRoot = try DemoScenarioE2EFixtures.makeSandboxRoot()
        harness = DemoScenarioE2EHarness(
            backend: backend,
            backendName: "Ollama",
            modelName: modelName
        )
    }

    override func tearDown() async throws {
        backend?.unloadModel()
        backend = nil
        harness = nil
        modelName = nil
        if let root = sandboxRoot {
            try? FileManager.default.removeItem(at: root)
        }
        sandboxRoot = nil
        try await super.tearDown()
    }

    // MARK: - Scenarios

    func test_tipCalc_invokesToolAndReturnsAnswer() async throws {
        let registry = ToolRegistry()
        registry.register(CalcTool.makeExecutor())

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "tip-calc",
                systemPrompt: "Use the `calc` tool for arithmetic. For an 18% tip on 73.40, call calc with a=73.40, op=*, b=0.18. Then answer in one sentence.",
                userPrompt: "What's an 18% tip on $73.40? Use multiplication, not addition.",
                expectedToolNames: ["calc"]
            ),
            registry: registry,
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "73.4", result: result)
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "*", result: result)
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "0.18", result: result)
        DemoScenarioOllamaAssertions.assertToolResultContains("13.212", trace: result.toolTraces[0], result: result)
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["13", "13.21"], result: result)
    }

    func test_worldClock_invokesToolAndReturnsAnswer() async throws {
        let registry = ToolRegistry()
        registry.register(DemoScenarioE2EFixtures.makeCurrentTimeExecutor())

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "world-clock",
                systemPrompt: "Use the `now` tool to answer time questions. For Tokyo, pass the exact IANA timezone `Asia/Tokyo` and answer with the tool result; do not guess the current time.",
                userPrompt: "What time is it in Tokyo right now?",
                expectedToolNames: ["now"]
            ),
            registry: registry,
        )
        XCTAssertTrue(
            result.dispatchedCalls.contains { call in
                call.arguments.contains("Asia/Tokyo") || call.arguments.contains("Asia\\/Tokyo")
            },
            "World-clock scenario should call now with Asia/Tokyo.\n\(result.diagnostics)"
        )
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["Tokyo", "JST", "Asia"], result: result)
    }

    func test_workspaceSearch_invokesToolAndReturnsAnswer() async throws {
        // Seed a tiny fixture file so sample_repo_search has something to find.
        let fixtureDir = sandboxRoot.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        try "Mention of MCP integration here.".write(
            to: fixtureDir.appendingPathComponent("ideas.md"),
            atomically: true,
            encoding: .utf8
        )

        let registry = ToolRegistry()
        registry.register(SampleRepoSearchTool.makeExecutor(root: sandboxRoot))

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "workspace-search",
                systemPrompt: "Use the `sample_repo_search` tool to look for the user's query. Then answer with a short summary.",
                userPrompt: "Find any note that mentions 'MCP'.",
                expectedToolNames: ["sample_repo_search"]
            ),
            registry: registry,
        )
        XCTAssertTrue(
            result.finalText.localizedCaseInsensitiveContains("MCP"),
            "Workspace-search answer should mention MCP.\n\(result.diagnostics)"
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "MCP", result: result)
        DemoScenarioOllamaAssertions.assertToolResultContains("ideas.md", trace: result.toolTraces[0], result: result)
    }

    func test_journalWrite_invokesToolAndReturnsAnswer() async throws {
        let registry = ToolRegistry()
        registry.register(DemoScenarioE2EFixtures.makeWriteFileExecutor(root: sandboxRoot))

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "journal-write",
                systemPrompt: "Use the `write_file` tool to save the user's content. Path must be relative. Then confirm in one sentence.",
                userPrompt: "Write a one-sentence journal entry to journal/today.md saying I had a productive day.",
                expectedToolNames: ["write_file"]
            ),
            registry: registry,
        )
        let journalPath = sandboxRoot!.appendingPathComponent("journal/today.md")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: journalPath.path),
            "Journal-write scenario should create journal/today.md.\n\(result.diagnostics)"
        )
        let journal = try String(contentsOf: journalPath, encoding: .utf8)
        XCTAssertTrue(
            journal.localizedCaseInsensitiveContains("productive"),
            "Journal-write scenario should persist the requested content.\n\(result.diagnostics)"
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "journal/today.md", result: result)
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["journal", "today.md", "saved", "wrote"], result: result)
    }

    func test_invalidArgsRecover_retriesAfterCalcError() async throws {
        let registry = ToolRegistry()
        registry.register(CalcTool.makeExecutor())

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "invalid-args-recover",
                systemPrompt: "Use the `calc` tool. First call calc with a=100, op=/, b=0. If that returns invalidArguments, call calc again with a=100, op=/, b=4. Then answer with the successful result.",
                userPrompt: "Demonstrate recovery from an invalid divide-by-zero calculator call.",
                expectedToolNames: ["calc", "calc"],
                maxIterations: 5
            ),
            registry: registry
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "\"b\":0", result: result)
        XCTAssertEqual(
            result.toolTraces[0].result.errorKind,
            .invalidArguments,
            "First calculator call should fail as invalidArguments.\n\(result.diagnostics)"
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[1], "4", result: result)
        DemoScenarioOllamaAssertions.assertToolResultContains("25", trace: result.toolTraces[1], result: result)
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["25", "zero", "divide"], result: result)
    }

    func test_rateLimitedRetry_retriesSameArguments() async throws {
        let registry = ToolRegistry()
        registry.register(DemoScenarioOllamaTestTools.makeRateLimitedExecutor())

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "rate-limited-retry",
                systemPrompt: "Use `fakeRateLimited` with query `ManifoldKit`. If the first call is rate-limited, retry the same call once and then report the successful result.",
                userPrompt: "Use fakeRateLimited to look up ManifoldKit.",
                expectedToolNames: ["fakeRateLimited", "fakeRateLimited"],
                maxIterations: 5
            ),
            registry: registry
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "ManifoldKit", result: result)
        XCTAssertEqual(
            DemoScenarioOllamaAssertions.normalized(result.dispatchedCalls[0].arguments),
            DemoScenarioOllamaAssertions.normalized(result.dispatchedCalls[1].arguments),
            "Retry should use the same arguments.\n\(result.diagnostics)"
        )
        XCTAssertEqual(result.toolTraces[0].result.errorKind, .rateLimited, "First call should be rate-limited.\n\(result.diagnostics)")
        XCTAssertNil(result.toolTraces[1].result.errorKind, "Retry should succeed.\n\(result.diagnostics)")
        DemoScenarioOllamaAssertions.assertToolResultContains("ManifoldKit", trace: result.toolTraces[1], result: result)
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["ManifoldKit", "succeeded", "retry"], result: result)
    }

    func test_mcpToolFailure_surfacesTransientFailure() async throws {
        let registry = ToolRegistry()
        registry.register(DemoScenarioOllamaTestTools.makeMCPLookupExecutor())

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "mcp-tool-failure",
                systemPrompt: "Use `fakeMCPLookup` once with path `/projects/scout`. The tool is expected to fail; do not retry. Explain the failure clearly.",
                userPrompt: "Call fakeMCPLookup for /projects/scout and tell me what happened.",
                expectedToolNames: ["fakeMCPLookup"]
            ),
            registry: registry
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "/projects/scout", result: result)
        XCTAssertEqual(result.toolTraces[0].result.errorKind, .transient, "MCP lookup should surface a transient failure.\n\(result.diagnostics)")
        DemoScenarioOllamaAssertions.assertToolResultContains("connection refused", trace: result.toolTraces[0], result: result)
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["connection", "refused", "MCP", "failed"], result: result)
    }

    func test_mcpEcho_invokesNamespacedEchoTool() async throws {
        let registry = ToolRegistry()
        registry.register(DemoScenarioOllamaTestTools.makeMCPEchoExecutor())

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "mcp-echo",
                systemPrompt: "Use `everything__echo` to repeat the exact message `Hello from ManifoldKit`, then confirm exactly what it returned.",
                userPrompt: "Echo Hello from ManifoldKit through the connected demo MCP server.",
                expectedToolNames: ["everything__echo"]
            ),
            registry: registry
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "Hello from ManifoldKit", result: result)
        DemoScenarioOllamaAssertions.assertToolResultContains("Hello from ManifoldKit", trace: result.toolTraces[0], result: result)
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["Hello from ManifoldKit", "echo"], result: result)
    }

    func test_meetingNotesSummary_listsAndReadsSeededNotes() async throws {
        try writeFixture("meetings/standup.md", "BetaLaunch owner: Riley. Status: ready for rollout.")
        try writeFixture("meetings/retro.md", "Retrospective notes without the launch marker.")

        let registry = ToolRegistry()
        registry.register(ListDirTool.makeExecutor(root: sandboxRoot))
        registry.register(ReadFileTool.makeExecutor(root: sandboxRoot))

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "meeting-notes-summary",
                systemPrompt: "First use `list_dir` with dir `meetings`. Then use `read_file` on `meetings/standup.md`. Answer with the BetaLaunch owner from the file.",
                userPrompt: "Summarize the relevant meeting note for BetaLaunch.",
                expectedToolNames: ["list_dir", "read_file"],
                maxIterations: 5
            ),
            registry: registry
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "meetings", result: result)
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[1], "meetings/standup.md", result: result)
        DemoScenarioOllamaAssertions.assertToolResultContains("Riley", trace: result.toolTraces[1], result: result)
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["Riley", "BetaLaunch"], result: result)
    }

    func test_shoppingListBudget_readsListAndCalculatesTotal() async throws {
        try writeFixture("shopping/list.md", "oranges: $4.20\nrice: $6.30\nignore candles: $9.99")

        let registry = ToolRegistry()
        registry.register(ReadFileTool.makeExecutor(root: sandboxRoot))
        registry.register(CalcTool.makeExecutor())

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "shopping-list-budget",
                systemPrompt: "Use `read_file` on `shopping/list.md`, then use `calc` to add only oranges 4.20 and rice 6.30. Answer with the total 10.50.",
                userPrompt: "What is the food total for oranges and rice in my shopping list?",
                expectedToolNames: ["read_file", "calc"],
                maxIterations: 5
            ),
            registry: registry
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "shopping/list.md", result: result)
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[1], "+", result: result)
        DemoScenarioOllamaAssertions.assertToolResultContains("10.5", trace: result.toolTraces[1], result: result)
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["10.5", "10.50", "$10"], result: result)
    }

    func test_parallelReadmeComparison_readsBothFiles() async throws {
        try writeFixture("repoA/README.md", "Repo A uses AlphaDB for persistence.")
        try writeFixture("repoB/README.md", "Repo B uses BetaCache for persistence.")

        let registry = ToolRegistry()
        registry.register(ReadFileTool.makeExecutor(root: sandboxRoot))

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "parallel-readme-comparison",
                systemPrompt: "Use `read_file` for both `repoA/README.md` and `repoB/README.md`, then compare the persistence technologies.",
                userPrompt: "Compare the persistence notes in repoA and repoB READMEs.",
                expectedToolNames: ["read_file", "read_file"],
                maxIterations: 5,
                allowsAdditionalToolCalls: true
            ),
            registry: registry
        )
        let combinedArguments = result.dispatchedCalls.map(\.arguments).joined(separator: "\n")
        let combinedResults = result.toolTraces.map(\.result.content).joined(separator: "\n")
        XCTAssertTrue(
            DemoScenarioOllamaAssertions.normalized(combinedArguments).localizedCaseInsensitiveContains("repoA/README.md"),
            "Parallel README scenario should read repoA/README.md.\n\(result.diagnostics)"
        )
        XCTAssertTrue(
            DemoScenarioOllamaAssertions.normalized(combinedArguments).localizedCaseInsensitiveContains("repoB/README.md"),
            "Parallel README scenario should read repoB/README.md.\n\(result.diagnostics)"
        )
        XCTAssertTrue(
            combinedResults.localizedCaseInsensitiveContains("AlphaDB"),
            "Parallel README tool results should include AlphaDB.\n\(result.diagnostics)"
        )
        XCTAssertTrue(
            combinedResults.localizedCaseInsensitiveContains("BetaCache"),
            "Parallel README tool results should include BetaCache.\n\(result.diagnostics)"
        )
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["AlphaDB", "BetaCache"], result: result)
    }

    func test_oversizeToolOutput_reportsMarkerFromLargeFile() async throws {
        let largeBody = Array(repeating: "padding line for context budget\n", count: 600).joined()
        try writeFixture("docs/large.md", "OVERSIZE-SENTINEL-ZEBRA\n" + largeBody)

        let registry = ToolRegistry()
        registry.register(ReadFileTool.makeExecutor(root: sandboxRoot))

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "oversize-tool-output",
                systemPrompt: "Use `read_file` on `docs/large.md`. The first line contains the marker; answer only with that marker.",
                userPrompt: "Read the large document and report its marker.",
                expectedToolNames: ["read_file"]
            ),
            registry: registry
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "docs/large.md", result: result)
        DemoScenarioOllamaAssertions.assertToolResultContains("OVERSIZE-SENTINEL-ZEBRA", trace: result.toolTraces[0], result: result)
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["OVERSIZE-SENTINEL-ZEBRA", "ZEBRA"], result: result)
    }

    func test_progressiveArgumentStreaming_composesEmailDraft() async throws {
        let registry = ToolRegistry()
        registry.register(DemoScenarioOllamaTestTools.makeComposeEmailExecutor())

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "progressive-argument-streaming",
                systemPrompt: "Use `compose_email` with to `mina@example.com`, subject `Project Falcon`, and a body that says `Project Falcon is ready for review`. Then answer with the draft id.",
                userPrompt: "Draft the Project Falcon status email to Mina.",
                expectedToolNames: ["compose_email"]
            ),
            registry: registry
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "mina@example.com", result: result)
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "Project Falcon", result: result)
        DemoScenarioOllamaAssertions.assertToolResultContains("draft-701", trace: result.toolTraces[0], result: result)
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["draft-701", "Project Falcon", "draft"], result: result)
    }

    func test_mcpFilesystemServer_readsFixtureThroughMCPTool() async throws {
        let registry = ToolRegistry()
        registry.register(DemoScenarioOllamaTestTools.makeMCPFilesystemReadExecutor())

        let result = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "mcp-filesystem-server",
                systemPrompt: "Use `mcp_fs_read` with path `/workspace/plan.md`, then answer with the migration status from the tool result.",
                userPrompt: "Read the MCP filesystem plan and tell me the status.",
                expectedToolNames: ["mcp_fs_read"]
            ),
            registry: registry
        )
        DemoScenarioOllamaAssertions.assertArgumentContains(result.dispatchedCalls[0], "/workspace/plan.md", result: result)
        DemoScenarioOllamaAssertions.assertToolResultContains("Neptune migration complete", trace: result.toolTraces[0], result: result)
        DemoScenarioOllamaAssertions.assertFinalTextContainsAny(["Neptune", "complete", "migration"], result: result)
    }

    private func writeFixture(_ relativePath: String, _ content: String) throws {
        let destination = sandboxRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: destination, atomically: true, encoding: .utf8)
    }
}
#endif
