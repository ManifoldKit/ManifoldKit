import Foundation
import ManifoldInference
import ManifoldRuntime

/// A minimal, always-scripted ``ToolExecutor`` used only by the starter
/// corpus's tool-round-trip example. Defined here (rather than reusing
/// `ManifoldTestSupport`'s `ScriptedResponseTool`) because ManifoldAppEval
/// deliberately carries no edge to `ManifoldTestSupport` — the design rule
/// that keeps the eval harness's dependency surface to `ManifoldInference` +
/// `ManifoldRuntime` only.
struct AppEvalEchoTool: ToolExecutor, @unchecked Sendable {
    let toolName: String
    let response: String

    var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "Scripted tool — returns a fixed response.",
            parameters: .object([:])
        )
    }

    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        ToolResult(callId: "", content: response)
    }
}

/// The public starter corpus shipped with ManifoldAppEval: 2–3 curated,
/// app-facing example scenarios that exercise the most common turn shapes an
/// adopting app will want goldens for.
///
/// Distinct from ``RuntimeScenarioRegistry``, which stays `package`-visible —
/// its 11 scenarios are MK's own demo/CI corpus and are shaped around MK's
/// internal turn-loop coverage, not app-facing examples. See design v2 §3.1,
/// Q2.
public enum AppEvalStarterCorpus {
    /// All starter scenarios, in a stable order.
    public static let all: [RuntimeScenario] = [
        .starterSendReceiveSmoke,
        .starterToolRoundTrip,
        .starterCancelMidStream,
    ]
}

extension RuntimeScenario {

    /// The simplest possible golden: one user message, one assistant reply.
    /// The template every adopting app starts from.
    public static let starterSendReceiveSmoke = RuntimeScenario(
        id: "starter-send-receive-smoke",
        displayName: "Send/Receive Smoke",
        scenarioDescription: "A single-turn conversation that yields plain text tokens. The minimal golden: proves the app's composition root can send a message and receive a complete reply.",
        userMessages: ["Hello, world."],
        scriptedTurns: [
            .tokens(["Hello", ",", " world", "!"])
        ],
        expectedSubsequence: [
            .streamStarted,
            .tokenEmitted,
            .streamFinished,
        ]
    )

    /// One user turn where the model requests a tool, the runtime
    /// auto-approves and executes it, then re-prompts for the final answer.
    public static let starterToolRoundTrip = RuntimeScenario(
        id: "starter-tool-roundtrip",
        displayName: "Tool Round Trip",
        scenarioDescription: "One user turn where the model requests a tool, the runtime auto-approves and executes it via the registry, then re-prompts for the final answer. Verifies toolCallRequested → toolCallApproved → toolCallCompleted ordering within a single stream lifecycle.",
        turns: [
            .send("Use the echo tool.")
        ],
        scriptedTurns: [
            .toolCall(ToolCall(id: "echo-1", toolName: "echo", arguments: "{}")),
            .tokens(["Echoed", " result", "."]),
        ],
        expectedSubsequence: [
            .streamStarted,
            .toolCallRequested,
            .toolCallApproved,
            .toolCallCompleted,
            .tokenEmitted,
            .streamFinished,
        ],
        toolExecutors: [
            AppEvalEchoTool(toolName: "echo", response: "Echo: hello")
        ]
    )

    /// A single turn cancelled mid-stream after the first token. Verifies the
    /// app's composition root terminates the turn with
    /// `streamFinished(.cancelled)` rather than running to natural completion.
    public static let starterCancelMidStream = RuntimeScenario(
        id: "starter-cancel-midstream",
        displayName: "Cancel Mid-Stream",
        scenarioDescription: "A single turn cancelled after the first streamed token. Verifies the runtime terminates the turn with streamFinished(.cancelled) rather than running to natural completion.",
        turns: [
            RuntimeScenario.ScenarioTurn(
                action: .send(text: "Cancel me partway through."),
                cancelAfterTokens: 1,
                streamingBatchCharacterLimit: 1
            )
        ],
        scriptedTurns: [
            .tokens(["Hello", " world", " this", " keeps", " going"])
        ],
        expectedSubsequence: [
            .streamStarted,
            .tokenEmitted,
            .streamFinished,
        ]
    )
}
