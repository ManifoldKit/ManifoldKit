import Foundation
import BaseChatTools

/// Per-scenario scripted-turn sequences for `ScriptedBackend`.
///
/// Each scenario's first turn emits the expected `.toolCall`; the second
/// emits a token-only synthesis the runner treats as the final assistant
/// message. Layer 2 XCUITests rely on this fixed shape — adding a new
/// scenario to `DemoScenarios.all` requires a matching entry here.
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
            // Same call twice — the demo tool's first invocation returns
            // `.rateLimited`; the second succeeds. Both calls carry identical
            // arguments to mirror what a well-behaved retry looks like.
            return [
                .toolCall(name: "fakeRateLimited", arguments: #"{"query":"BaseChatKit"}"#),
                .toolCall(name: "fakeRateLimited", arguments: #"{"query":"BaseChatKit"}"#),
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
                .toolCall(name: "everything__echo", arguments: #"{"message":"Hello from BaseChatKit"}"#),
                .tokens([
                    "The ", "MCP ", "echo ", "server ", "replied: ",
                    "'Hello ", "from ", "BaseChatKit'."
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
