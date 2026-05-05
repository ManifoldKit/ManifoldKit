import Foundation

/// Registry of P1 demo scenarios. Adding a new scenario means adding an
/// entry here and a corresponding turn sequence in `DemoScenarios+Scripts.swift`.
enum DemoScenarios {

    static let tipCalc = DemoScenario(
        id: "tip-calc",
        title: "Split the bill",
        blurb: "Tip 18% on $73.40 and split it four ways — single tool call.",
        systemImage: "dollarsign.circle",
        prompt: "What's an 18% tip on $73.40, and what's each person's share for 4 people?",
        systemPrompt: "Use the `calc` tool for arithmetic in the user's request, then answer in one short sentence.",
        expectedTools: ["calc"],
        autoSend: true,
        accessibilityID: "demo-card-tip-calc",
        configure: nil
    )

    static let worldClock = DemoScenario(
        id: "world-clock",
        title: "What time is it in Tokyo?",
        blurb: "A single tool call with a non-numeric argument.",
        systemImage: "clock",
        prompt: "What time is it in Tokyo right now?",
        systemPrompt: "Use the `now` tool to answer time questions. For Tokyo, pass the exact IANA timezone `Asia/Tokyo` and answer with the tool result; do not guess the current time.",
        expectedTools: ["now"],
        autoSend: true,
        accessibilityID: "demo-card-world-clock",
        configure: nil
    )

    static let workspaceSearch = DemoScenario(
        id: "workspace-search",
        title: "Find that note",
        blurb: "Search a fixture workspace and cite the matching line.",
        systemImage: "magnifyingglass",
        prompt: "Find any note that mentions 'MCP' and quote the line.",
        systemPrompt: "Use the `sample_repo_search` tool to search the workspace for the user's query, then answer with a short summary that quotes a matching line.",
        expectedTools: ["sample_repo_search"],
        autoSend: true,
        accessibilityID: "demo-card-workspace-search",
        configure: nil
    )

    static let journalWrite = DemoScenario(
        id: "journal-write",
        title: "Save with my permission",
        blurb: "Triggers the per-call approval sheet before a side-effecting tool runs.",
        systemImage: "square.and.pencil",
        prompt: "Write a short journal entry for today named 'today.md' with a one-sentence mood summary.",
        systemPrompt: "Use the `write_file` tool to save the user's journal entry. Write to a relative path under `journal/`, ask for approval through the tool call, then confirm in one short sentence.",
        expectedTools: ["write_file"],
        autoSend: false,
        accessibilityID: "demo-card-journal-write",
        configure: nil
    )

    static let invalidArgsRecover = DemoScenario(
        id: "invalid-args-recover",
        title: "Recover from bad args",
        blurb: "Tempts a divide-by-zero. The tool returns invalidArguments and the model retries with corrected inputs.",
        systemImage: "exclamationmark.arrow.triangle.2.circlepath",
        prompt: "Use the calculator to divide 100 by 0, then try a similar division you can actually answer.",
        systemPrompt: "Use the `calc` tool. If the first call fails because the arguments are invalid, correct them and retry within the same answer.",
        expectedTools: ["calc"],
        autoSend: true,
        accessibilityID: "demo-card-invalid-args-recover",
        configure: nil
    )

    static let rateLimitedRetry = DemoScenario(
        id: "rate-limited-retry",
        title: "Retry through a rate limit",
        blurb: "First call returns rateLimited; the model sees the error and retries the same call within one turn.",
        systemImage: "hourglass.tophalf.filled",
        prompt: "Use fakeRateLimited to look up 'BaseChatKit' and report the result it returns.",
        systemPrompt: "Use the `fakeRateLimited` tool. If the first call is rate-limited, retry the same call once and report the successful result.",
        expectedTools: ["fakeRateLimited"],
        autoSend: true,
        accessibilityID: "demo-card-rate-limited-retry",
        configure: nil
    )

    static let mcpToolFailure = DemoScenario(
        id: "mcp-tool-failure",
        title: "Surface an MCP failure",
        blurb: "An MCP-style tool fails transiently. The model receives the error and tells the user what went wrong.",
        systemImage: "bolt.horizontal.icloud",
        prompt: "Call fakeMCPLookup for the path '/projects/scout' and tell me what happened.",
        systemPrompt: "Use the `fakeMCPLookup` tool once, then explain the failure clearly instead of retrying.",
        expectedTools: ["fakeMCPLookup"],
        autoSend: true,
        accessibilityID: "demo-card-mcp-tool-failure",
        configure: nil
    )

    static let mcpEcho = DemoScenario(
        id: "mcp-echo",
        // Calls a tool whose definition was discovered from a real MCP
        // server (the official `@modelcontextprotocol/server-everything`),
        // not from a hardcoded `ScriptedBackend` tool. Open Connected
        // Services > "Demo Echo (local, via npx)" and tap Connect first;
        // the registry binds `everything__echo` and the scenario routes
        // through it. macOS-only because the underlying stdio transport
        // is gated to macOS.
        title: "Echo via an MCP server",
        blurb: "Connect 'Demo Echo' in Connected Services first (macOS, requires npx). Then this scenario routes a tool call through the live MCP server.",
        systemImage: "antenna.radiowaves.left.and.right",
        prompt: "Use the everything echo tool to repeat back the message 'Hello from BaseChatKit'.",
        systemPrompt: "Use the `everything__echo` tool to repeat the provided message, then confirm exactly what it returned.",
        expectedTools: ["everything__echo"],
        autoSend: true,
        accessibilityID: "demo-card-mcp-echo",
        configure: nil
    )

    /// Order matches card display order on the empty state.
    static let all: [DemoScenario] = [
        tipCalc,
        worldClock,
        workspaceSearch,
        journalWrite,
        invalidArgsRecover,
        rateLimitedRetry,
        mcpToolFailure,
        mcpEcho
    ]

    static func scenario(id: String) -> DemoScenario? {
        all.first { $0.id == id }
    }
}
