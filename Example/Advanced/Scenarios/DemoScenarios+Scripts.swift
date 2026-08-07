import Foundation
import ManifoldTools

/// Per-scenario scripted-turn sequences for `ScriptedBackend`.
///
/// Each scenario's first turn emits the expected `.toolCall`; the second
/// emits a token-only synthesis the runner treats as the final assistant
/// message. Layer 2 XCUITests rely on this fixed shape — adding a new
/// scenario to `DemoScenarios.all` requires a matching entry here.
///
/// `ScriptedBackend` pops one entry per `generate(...)` call regardless of
/// which runtime turn asked for it, so this two-entry shape works
/// identically whether both calls land in one `sendMessage` (normal tool
/// dispatch continues the loop) or in two (`handoff-research-write`'s second
/// entry is consumed by `DemoScenarioRunner`'s automatic follow-up turn —
/// see `DemoScenario.handoffFollowUpPrompt` — because a genuine handoff is
/// turn-scoped and never triggers a second `generate()` call on its own).
extension DemoScenarios {

    /// Returns the turn list for `scenarioID`, or a small fallback when no
    /// scenario was supplied via the launch arg (preserves the legacy
    /// `--uitesting`-only behaviour for `ToolApprovalUITests` and similar).
    static func scriptedTurns(for scenarioID: String?) -> [ScriptedBackend.Turn] {
        guard let scenarioID else { return fallbackTurns }
        switch scenarioID {
        case tipCalc.id:
            return [
                // CalcTool.Args expects {a, op, b}; `expression` is not part of
                // the schema and would fail the real executor's Decodable probe.
                .toolCall(name: "calc", arguments: #"{"a":73.40,"op":"*","b":0.18}"#),
                .tokens([
                    "An ", "18% ", "tip ", "on ", "$73.40 ", "is ", "$13.21. ",
                    "Each ", "person's ", "share ", "is ", "about ", "$21.65."
                ])
            ]

        case worldClock.id:
            return [
                // The demo-local executor accepts an optional IANA timezone.
                // Tokyo must route through Asia/Tokyo so the scripted UI path
                // matches what the real demo now asks models to do.
                .toolCall(name: "now", arguments: #"{"timezone":"Asia/Tokyo"}"#),
                .tokens([
                    "It's ", "currently ", "time ", "in ", "Tokyo."
                ])
            ]

        case workspaceSearch.id:
            return [
                .toolCall(name: "sample_repo_search", arguments: #"{"query":"MCP"}"#),
                .tokens([
                    "I ", "found ", "a ", "match ", "in ", "your ", "workspace ",
                    "mentioning ", "MCP."
                ])
            ]

        case journalWrite.id:
            // Use a plain Swift string (not a raw string) so JSON \n escapes
            // remain valid two-character sequences when decoded.
            let body = "{\"path\":\"journal/today.md\",\"content\":\"# Today\\n\\nQuiet, focused day.\"}"
            return [
                .toolCall(name: "write_file", arguments: body),
                .tokens([
                    "Saved ", "today's ", "journal ", "entry."
                ])
            ]

        case invalidArgsRecover.id:
            // First call divides by zero — CalcTool returns `.invalidArguments`.
            // Orchestrator threads the error back; the model recovers with a
            // valid divisor on the second turn before producing prose.
            return [
                .toolCall(name: "calc", arguments: #"{"a":100,"op":"/","b":0}"#),
                .toolCall(name: "calc", arguments: #"{"a":100,"op":"/","b":4}"#),
                .tokens([
                    "Dividing ", "by ", "zero ", "isn't ", "defined, ",
                    "but ", "100 ÷ 4 ", "is ", "25."
                ])
            ]

        case rateLimitedRetry.id:
            // The demo tool's first invocation returns `.rateLimited`; the
            // second succeeds. Keep the user-visible query identical while
            // adding a retry marker so the orchestrator's duplicate-call guard
            // does not short-circuit the scripted recovery.
            return [
                .toolCall(name: "fakeRateLimited", arguments: #"{"query":"ManifoldKit"}"#),
                .toolCall(name: "fakeRateLimited", arguments: #"{"query":"ManifoldKit","retry":true}"#),
                .tokens([
                    "The ", "first ", "call ", "was ", "rate-limited, ",
                    "but ", "the ", "retry ", "succeeded."
                ])
            ]

        case mcpToolFailure.id:
            // Single call — the demo tool always returns `.transient`. The
            // model reports the failure rather than looping (the tool's
            // description tells it not to retry).
            return [
                .toolCall(name: "fakeMCPLookup", arguments: #"{"path":"/projects/scout"}"#),
                .tokens([
                    "The ", "MCP ", "lookup ", "failed: ", "the ",
                    "remote ", "server ", "is ", "unreachable."
                ])
            ]

        case mcpEcho.id:
            // Targets the namespaced name produced by `MCPToolSource` when the
            // descriptor's `toolNamespace` is "everything" — the live tool
            // surfaced by `@modelcontextprotocol/server-everything` after the
            // user taps Connect. Under `--uitesting`, ScriptedBackend dispatches
            // the same name; if the user hasn't connected, the registry
            // returns `.notFound` and the model would normally apologise — but
            // the scripted second turn goes straight to a confirmation summary
            // so the demo recording stays predictable for XCUITests.
            return [
                .toolCall(name: "everything__echo", arguments: #"{"message":"Hello from ManifoldKit"}"#),
                .tokens([
                    "The ", "MCP ", "echo ", "server ", "replied: ",
                    "'Hello ", "from ", "ManifoldKit'."
                ])
            ]

        case handoffResearchWrite.id:
            // Researcher emits transfer_to_writer with an outline payload;
            // under the live runtime path the executor would swap
            // ChatSession.activeAgentID and Writer's system prompt drives the
            // next turn. The scripted second turn stands in for Writer.
            let outline = "1. MCP is a JSON-RPC protocol. 2. Tools/resources are advertised over stdio. 3. Hosts route model tool calls through the server."
            let payload = "{\"payload\":\"\(outline)\"}"
            return [
                .toolCall(name: "transfer_to_writer", arguments: payload),
                .tokens([
                    "MCP ", "is ", "a ", "JSON-RPC ", "protocol ", "that ", "lets ",
                    "hosts ", "advertise ", "tools ", "and ", "resources ", "to ",
                    "model ", "runtimes."
                ])
            ]

        case hookInputSanitize.id:
            // The user-supplied path is `../../../etc/passwd`. The
            // `preToolUse` hook in the live runtime rewrites it to a
            // sandboxed prefix BEFORE the executor sees it — the scripted
            // backend emits the post-hook path so the UITest can assert the
            // rendered tool invocation reflects the sanitised target.
            return [
                .toolCall(name: "read_file", arguments: #"{"path":"sandbox/etc/passwd"}"#),
                .tokens([
                    "The ", "requested ", "path ", "was ", "rewritten ", "to ",
                    "sandbox/etc/passwd ", "before ", "the ", "tool ", "ran."
                ])
            ]

        default:
            return fallbackTurns
        }
    }

    /// Legacy turn list for `--uitesting` runs without a scenario arg —
    /// preserves `ToolApprovalUITests` behaviour against the README search.
    private static let fallbackTurns: [ScriptedBackend.Turn] = [
        .toolCall(name: "sample_repo_search", arguments: #"{"query":"readme"}"#),
        .tokens(["Here's ", "a ", "summary ", "of ", "your ", "workspace."])
    ]
}
