import Foundation
import ManifoldInference

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
        prompt: "Use fakeRateLimited to look up 'ManifoldKit' and report the result it returns.",
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
        prompt: "Use the everything echo tool to repeat back the message 'Hello from ManifoldKit'.",
        systemPrompt: "Use the `everything__echo` tool to repeat the provided message, then confirm exactly what it returned.",
        expectedTools: ["everything__echo"],
        autoSend: true,
        accessibilityID: "demo-card-mcp-echo",
        configure: nil
    )

    // MARK: - W3B scenarios (Wave 3B of put-an-implementation-plan-reactive-penguin)

    /// Two-agent session (Researcher → Writer). Researcher emits
    /// `transfer_to_writer` with an outline payload; the runtime swaps agents
    /// and Writer produces the final prose. The `expectedHandoffs` assertion
    /// fires LOUDLY if the model never emits the transfer call — the scripted
    /// UITest path mimics the successful run for deterministic CI.
    /// Two pinned agent IDs so the `configureContext` closure can install
    /// a stable roster and so tests can pin the expected `activeAgentID`.
    /// Using deterministic UUIDs (rather than `UUID()` inside the closure)
    /// keeps the scenario's behaviour reproducible run-to-run, which is
    /// important for the scripted UITest path.
    static let researcherAgentID = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
    static let writerAgentID = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!

    static let handoffResearchWrite = DemoScenario(
        id: "handoff-research-write",
        title: "Handoff: Researcher → Writer",
        blurb: "Two agents in one session. Researcher outlines, then hands off to Writer for prose.",
        systemImage: "person.2.fill",
        prompt: "Outline a 3-paragraph explanation of how MCP works, then hand it off to Writer to draft.",
        // Per-agent prompts come from the agent registry under the live
        // runtime path; the demo card carries a fallback steering prompt for
        // single-agent backends so the scripted card still tells the model
        // what to do under --uitesting.
        systemPrompt: "You are Researcher. Produce a short outline, then call `transfer_to_writer` with the outline as the `payload` argument so Writer can draft prose.",
        expectedTools: ["transfer_to_writer"],
        autoSend: true,
        accessibilityID: "demo-card-handoff-research-write",
        configure: nil,
        // Wires the two-agent roster onto the freshly-created session so the
        // turn loop's HandoffToolSource sees both agents and can synthesise
        // `transfer_to_writer`. Researcher is active first; the handoff
        // tool-call flips `activeAgentID` to Writer for the next turn.
        configureContext: { context in
            let researcher = AgentDefinition(
                id: researcherAgentID,
                name: "Researcher",
                systemPrompt: "You are Researcher. Produce a tight outline, then call `transfer_to_writer` with the outline as the `payload` so Writer can draft prose.",
                description: "Outlines a topic before handing off to Writer.",
                allowedToolNames: nil
            )
            let writer = AgentDefinition(
                id: writerAgentID,
                name: "Writer",
                systemPrompt: "You are Writer. Turn Researcher's outline into three short paragraphs of clear prose.",
                description: "Drafts prose from an outline.",
                allowedToolNames: nil
            )
            context.agents = [researcher, writer]
            context.activeAgentID = researcherAgentID
        },
        expectedHandoffs: ["transfer_to_writer"],
        // 3B-class models cannot reliably emit transfer_to_* on first attempt;
        // gate at .balanced (≈8B+) so the card shows an "install a larger
        // model" hint when the active backend is below the bar.
        minCapableModel: .balanced,
        // Handoffs are turn-scoped (docs/.../AgentHandoffs.md): Researcher's
        // turn swaps the active agent but produces no answer of its own —
        // Writer's prose is the *next* turn's job. Without this, the runner
        // sends one prompt, sees Researcher's transfer, and stops; the card
        // never shows the payoff the scenario exists to demonstrate (#2378).
        handoffFollowUpPrompt: "Go ahead and draft it, Writer."
    )

    /// Demonstrates the W2C `preToolUse` hook: a path-traversal-shaped
    /// `read_file` argument is rewritten into a sandboxed prefix BEFORE the
    /// tool executor is dispatched. The scripted UITest verifies the result
    /// content reflects the sanitised path, not the user-supplied traversal.
    static let hookInputSanitize = DemoScenario(
        id: "hook-input-sanitize",
        title: "Hook: sanitize tool input",
        blurb: "preToolUse hook rewrites read_file paths into a sandbox dir before dispatch.",
        systemImage: "shield.lefthalf.filled",
        prompt: "Read the file ../../../etc/passwd",
        systemPrompt: "You are a helpful assistant. Use the `read_file` tool when asked to read a file. Pass the user's path verbatim — the runtime will sanitise it.",
        expectedTools: ["read_file"],
        autoSend: true,
        accessibilityID: "demo-card-hook-input-sanitize",
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
        mcpEcho,
        handoffResearchWrite,
        hookInputSanitize
    ]

    static func scenario(id: String) -> DemoScenario? {
        all.first { $0.id == id }
    }
}
