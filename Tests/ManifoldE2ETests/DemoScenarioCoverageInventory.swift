/// Stable inventory for the #754 demo-scenario coverage matrix.
///
/// Wave 0 keeps this in test code rather than adding production scenario
/// resources: later workers can extend the rows as they add per-scenario test
/// layers without touching unrelated package or release files.
enum DemoScenarioCoverageInventory {
    struct Entry: Sendable, Equatable {
        let scenarioID: String
        let issue: String
        let toolset: [String]
        let existingTests: [String]
        let missingTestLayers: [String]
        let requiredTraits: [String]
        let environmentGates: [String]
        let notes: String
    }

    static let issue754: [Entry] = [
        Entry(
            scenarioID: "tip-calc",
            issue: "#754 baseline",
            toolset: ["calc"],
            existingTests: ["DemoScenarioOllamaE2ETests", "DemoScenarioUITests"],
            missingTestLayers: ["dedicated demo tool-logic unit row"],
            requiredTraits: ["Ollama", "Tools"],
            environmentGates: ["Ollama localhost:11434", "OLLAMA_TEST_MODEL optional fail-loud pin"],
            notes: "Current P1 arithmetic smoke used by the shared E2E harness."
        ),
        Entry(
            scenarioID: "world-clock",
            issue: "#695",
            toolset: ["now"],
            existingTests: ["DemoScenarioOllamaE2ETests", "DemoScenarioUITests"],
            missingTestLayers: ["dedicated demo tool-logic unit row"],
            requiredTraits: ["Ollama", "Tools"],
            environmentGates: ["Ollama localhost:11434", "tool-calling-capable local model"],
            notes: "Asserts Asia/Tokyo argument in the Ollama E2E layer."
        ),
        Entry(
            scenarioID: "workspace-search",
            issue: "#696",
            toolset: ["sample_repo_search"],
            existingTests: ["DemoScenarioOllamaE2ETests", "DemoScenarioUITests"],
            missingTestLayers: ["dedicated demo tool-logic unit row"],
            requiredTraits: ["Ollama", "Tools"],
            environmentGates: ["Ollama localhost:11434", "seeded sandbox workspace"],
            notes: "Uses a per-test fixture root so search results are deterministic."
        ),
        Entry(
            scenarioID: "journal-write",
            issue: "#700",
            toolset: ["write_file"],
            existingTests: ["DemoScenarioOllamaE2ETests", "DemoScenarioUITests"],
            missingTestLayers: ["dedicated demo approval unit row"],
            requiredTraits: ["Ollama", "Tools"],
            environmentGates: ["Ollama localhost:11434", "writable sandbox root"],
            notes: "E2E auto-approves the side effect and asserts the file exists."
        ),
        Entry(
            scenarioID: "invalid-args-recover",
            issue: "#754 failure-path extension",
            toolset: ["calc"],
            existingTests: ["DemoScenarios.scriptedTurns(for:)"],
            missingTestLayers: ["tool-logic unit", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["Tools", "Ollama for real E2E"],
            environmentGates: ["tool loop enabled"],
            notes: "Current demo card; not part of the Wave 0 four-test E2E set."
        ),
        Entry(
            scenarioID: "rate-limited-retry",
            issue: "#754 failure-path extension",
            toolset: ["fakeRateLimited"],
            existingTests: ["DemoScenarios.scriptedTurns(for:)"],
            missingTestLayers: ["tool-logic unit", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["Tools", "Ollama for real E2E"],
            environmentGates: ["tool loop enabled"],
            notes: "Current demo card exercising retriable ToolResult.ErrorKind."
        ),
        Entry(
            scenarioID: "mcp-tool-failure",
            issue: "#754 failure-path extension",
            toolset: ["fakeMCPLookup"],
            existingTests: ["DemoScenarios.scriptedTurns(for:)"],
            missingTestLayers: ["tool-logic unit", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["Tools", "Ollama for real E2E"],
            environmentGates: ["tool loop enabled"],
            notes: "Current demo card simulating transient MCP transport failure."
        ),
        Entry(
            scenarioID: "mcp-echo",
            issue: "#754 MCP extension",
            toolset: ["everything__echo"],
            existingTests: ["DemoScenarios.scriptedTurns(for:)"],
            missingTestLayers: ["tool-logic unit", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["Tools", "MCP for live source", "Ollama for real E2E"],
            environmentGates: ["macOS", "npx", "connected everything MCP server"],
            notes: "Current demo card; live MCP source must be connected before use."
        ),
        Entry(
            scenarioID: "meeting-notes-summary",
            issue: "#697",
            toolset: ["list_dir", "read_file"],
            existingTests: [],
            missingTestLayers: ["tool-logic unit", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["Tools", "Ollama for real E2E"],
            environmentGates: ["seeded notes fixture", "multi-turn tool loop"],
            notes: "P2 headline agent-loop scenario; #707 reuses this shape."
        ),
        Entry(
            scenarioID: "shopping-list-budget",
            issue: "#698",
            toolset: ["read_file", "calc"],
            existingTests: [],
            missingTestLayers: ["tool-logic unit", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["Tools", "Ollama for real E2E"],
            environmentGates: ["seeded shopping-list fixture", "multi-turn tool loop"],
            notes: "Mixed-tool chain: text retrieval, arithmetic, synthesis."
        ),
        Entry(
            scenarioID: "parallel-readme-comparison",
            issue: "#699",
            toolset: ["read_file", "read_file"],
            existingTests: [],
            missingTestLayers: ["tool-logic unit", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["Tools", "Ollama for real E2E"],
            environmentGates: ["parallel tool-call support", "seeded README fixtures"],
            notes: "P3 scenario bundled with parallel tool-call capability."
        ),
        Entry(
            scenarioID: "progressive-argument-streaming",
            issue: "#701",
            toolset: ["composeEmail or equivalent large-argument tool"],
            existingTests: [],
            missingTestLayers: ["tool-logic unit", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["Tools", "Ollama for real E2E"],
            environmentGates: ["tool-call delta streaming support"],
            notes: "P3 UI streaming scenario; tool definition is capability-owned."
        ),
        Entry(
            scenarioID: "cancel-mid-search",
            issue: "#702",
            toolset: ["slow sample_repo_search"],
            existingTests: [],
            missingTestLayers: ["tool-logic unit", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["Tools", "Ollama for real E2E"],
            environmentGates: ["cancellation contract", "slow fixture search"],
            notes: "P3 cancellation scenario; do not add in Wave 0."
        ),
        Entry(
            scenarioID: "oversize-tool-output",
            issue: "#703",
            toolset: ["read_file"],
            existingTests: [],
            missingTestLayers: ["tool-logic unit", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["Tools", "Ollama for real E2E"],
            environmentGates: ["oversize fixture", "ToolOutputPolicy configured"],
            notes: "P3 output-policy scenario."
        ),
        Entry(
            scenarioID: "crash-recovery",
            issue: "#704",
            toolset: ["slow sample_repo_search"],
            existingTests: [],
            missingTestLayers: ["tool-logic integration", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["Tools", "Ollama for real E2E"],
            environmentGates: ["SwiftData session reload", "app terminate/relaunch harness"],
            notes: "Recovery test hits persistence; keep separate from pure harness."
        ),
        Entry(
            scenarioID: "create-reminder",
            issue: "#705",
            toolset: ["AppIntent reminder tool"],
            existingTests: [],
            missingTestLayers: ["tool-logic unit", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["AppIntents", "Tools", "Ollama for real E2E"],
            environmentGates: ["Reminders/EventKit permission", "platform availability"],
            notes: "P3 native API scenario; should ship with AppIntent capability."
        ),
        Entry(
            scenarioID: "mcp-filesystem-server",
            issue: "#706",
            toolset: ["mcp_fs_read"],
            existingTests: [],
            missingTestLayers: ["tool-logic unit", "mock XCUITest", "real Ollama E2E"],
            requiredTraits: ["MCP", "Tools", "Ollama for real E2E"],
            environmentGates: ["filesystem MCP server fixture", "Ollama localhost:11434"],
            notes: "Still missing per #754 audit; do not implement in Wave 0."
        ),
        Entry(
            scenarioID: "cross-backend-agent",
            issue: "#707",
            toolset: ["list_dir", "read_file"],
            existingTests: ["Ollama leg covered indirectly by current four E2Es only for P1"],
            missingTestLayers: ["Claude E2E", "Foundation E2E", "cross-backend mock contract"],
            requiredTraits: ["Tools", "Ollama", "CloudSaaS", "Foundation availability"],
            environmentGates: ["Ollama server", "Claude credentials", "iOS 26/macOS 26 Foundation Models"],
            notes: "Still missing per #754 audit; later workers should reuse the shared harness."
        ),
        Entry(
            scenarioID: "structured-json-extraction",
            issue: "#708",
            toolset: [],
            existingTests: [],
            missingTestLayers: ["strategy unit", "mock XCUITest", "Ollama/Llama E2E"],
            requiredTraits: ["Llama for grammar leg", "Ollama for real E2E"],
            environmentGates: ["grammar-constrained output support", "schema fixture"],
            notes: "Tool-free scenario; harness inventory tracks it so it is not lost."
        )
    ]
}
