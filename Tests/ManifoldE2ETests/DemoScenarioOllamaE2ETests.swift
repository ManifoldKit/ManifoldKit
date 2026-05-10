#if Ollama && Tools
import XCTest
import ManifoldInference
import ManifoldTools
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// True end-to-end coverage of the four P1 demo scenarios against a real
/// local Ollama server.
///
/// Local-only: `XCTSkipUnless(HardwareRequirements.hasOllamaServer)` and the
/// preferred-model gate match the pattern in `OllamaToolCallingE2ETests`.
/// Not run in CI.
///
/// Assertion strategy is deliberately loose — the model is free to phrase
/// the final visible answer however it likes; we only assert that at least
/// one tool call was dispatched and that a non-empty visible answer arrived.
/// Tighter assertions on tool name / argument shape are covered at Layer 1
/// (mock-backed) and Layer 2 (XCUITest with scripted backend).
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

        _ = try await harness.runAndAssert(
            DemoScenarioE2ESpec(
                id: "tip-calc",
                systemPrompt: "Use the `calc` tool to evaluate any arithmetic in the user's question. Then answer in one sentence.",
                userPrompt: "What's an 18% tip on $73.40?",
                expectedToolNames: ["calc"]
            ),
            registry: registry,
        )
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
    }
}
#endif
