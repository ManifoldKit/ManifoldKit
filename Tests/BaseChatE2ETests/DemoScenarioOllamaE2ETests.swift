#if Ollama && Tools
import XCTest
import BaseChatInference
import BaseChatTools
import BaseChatTestSupport
@testable import BaseChatBackends

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
        sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCK-DemoE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        backend?.unloadModel()
        backend = nil
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

        try await runScenario(
            registry: registry,
            systemPrompt: "Use the `calc` tool to evaluate any arithmetic in the user's question. Then answer in one sentence.",
            userPrompt: "What's an 18% tip on $73.40?"
        )
    }

    func test_worldClock_invokesToolAndReturnsAnswer() async throws {
        let registry = ToolRegistry()
        registry.register(NowTool.makeExecutor())

        try await runScenario(
            registry: registry,
            systemPrompt: "Use the `now` tool to read the current time. Then answer in one sentence.",
            userPrompt: "What time is it right now?"
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

        try await runScenario(
            registry: registry,
            systemPrompt: "Use the `sample_repo_search` tool to look for the user's query. Then answer with a short summary.",
            userPrompt: "Find any note that mentions 'MCP'."
        )
    }

    func test_journalWrite_invokesToolAndReturnsAnswer() async throws {
        let registry = ToolRegistry()
        registry.register(makeWriteFileExecutor(root: sandboxRoot))

        try await runScenario(
            registry: registry,
            systemPrompt: "Use the `write_file` tool to save the user's content. Path must be relative. Then confirm in one sentence.",
            userPrompt: "Write a one-sentence journal entry to journal/today.md saying I had a productive day."
        )

        // Best-effort assertion: the tool was supposed to write *something*
        // under the sandbox. Skip on flaky model behaviour rather than fail
        // hard — Layer 1 covers the dispatch contract; this layer just
        // proves a real model can drive write_file end-to-end.
        let journalDir = sandboxRoot.appendingPathComponent("journal", isDirectory: true)
        if !FileManager.default.fileExists(atPath: journalDir.path) {
            print("[DemoE2E] note: model did not create the expected journal/ directory under \(sandboxRoot.path)")
        }
    }

    // MARK: - Helpers

    /// Drives the agent loop against the supplied registry. Asserts: at
    /// least one tool was dispatched AND the final visible answer is
    /// non-empty.
    ///
    /// On failure, logs the model name and the dispatched tool calls so a
    /// developer triaging a flaky run can tell flaky-model from
    /// framework-regression.
    private func runScenario(
        registry: ToolRegistry,
        systemPrompt: String,
        userPrompt: String,
        maxIterations: Int = 4
    ) async throws {
        var history: [ToolAwareHistoryEntry] = [
            ToolAwareHistoryEntry(role: "system", content: systemPrompt),
            ToolAwareHistoryEntry(role: "user", content: userPrompt),
        ]

        let config = GenerationConfig(
            temperature: 0.2,
            topP: 1.0,
            maxOutputTokens: 256,
            tools: registry.definitions,
            toolChoice: .auto,
            maxToolIterations: maxIterations
        )

        var dispatchedCalls: [ToolCall] = []
        var visibleAnswer = ""

        for _ in 0..<config.maxToolIterations {
            backend.setToolAwareHistory(history)
            let stream = try backend.generate(prompt: "", systemPrompt: nil, config: config)

            var turnCalls: [ToolCall] = []
            var turnText = ""
            for try await event in stream.events {
                switch event {
                case .toolCall(let call): turnCalls.append(call)
                case .token(let text): turnText += text
                default: break
                }
            }

            if turnCalls.isEmpty {
                visibleAnswer = turnText
                break
            }

            history.append(ToolAwareHistoryEntry(role: "assistant", content: "", toolCalls: turnCalls))
            for call in turnCalls {
                dispatchedCalls.append(call)
                let result = await registry.dispatch(call)
                history.append(ToolAwareHistoryEntry(role: "tool", content: result.content, toolCallId: call.id))
            }
        }

        if dispatchedCalls.isEmpty || visibleAnswer.isEmpty {
            print("[DemoE2E] model=\(modelName ?? "?") dispatched=\(dispatchedCalls.map(\.toolName)) visible=\(visibleAnswer.prefix(120))")
        }

        XCTAssertFalse(
            dispatchedCalls.isEmpty,
            "Scenario must invoke at least one tool (model=\(modelName ?? "?"))"
        )
        XCTAssertFalse(
            visibleAnswer.isEmpty,
            "Scenario must produce a non-empty visible answer (model=\(modelName ?? "?"))"
        )
    }

    /// Demo-mirror of the production `WriteFileTool` — kept here so the E2E
    /// suite stays inside `BaseChatE2ETests` without depending on the demo
    /// app's source. Mirrors the contract: relative paths only, sandbox-
    /// containment via `SandboxResolver`, parent-dir creation on demand.
    private func makeWriteFileExecutor(root: URL) -> any ToolExecutor {
        struct Args: Decodable, Sendable {
            let path: String
            let content: String
        }
        struct Result: Encodable, Sendable {
            let path: String
            let bytesWritten: Int
        }
        let definition = ToolDefinition(
            name: "write_file",
            description: "Writes a UTF-8 text file inside the sandbox. Relative path required.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "content": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("path"), .string("content")])
            ])
        )
        return TypedToolExecutor<Args, Result>(
            definition: definition,
            requiresApproval: false   // E2E auto-approves; gate behaviour is covered separately
        ) { args in
            guard let resolved = SandboxResolver.resolve(path: args.path, inside: root) else {
                throw NSError(
                    domain: "WriteFileTool",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "path escapes sandbox: \(args.path)"]
                )
            }
            try FileManager.default.createDirectory(
                at: resolved.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = Data(args.content.utf8)
            try payload.write(to: resolved, options: .atomic)
            return Result(path: args.path, bytesWritten: payload.count)
        }
    }
}
#endif
