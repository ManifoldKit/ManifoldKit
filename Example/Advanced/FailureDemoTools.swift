import Foundation
import ManifoldInference

/// Demo-only tools that exercise the unified `ToolResult.ErrorKind`
/// classification + retry behaviour from the orchestration loop.
///
/// These exist purely so the empty-state scenario picker can show the
/// framework's error story (invalid args, transient rate limits, MCP
/// failures) end-to-end. Production code should not use them — the
/// fakeRateLimited tool is stateful (failing on the first call and
/// succeeding thereafter) and the fakeMCPLookup tool always fails.
///
/// Both are registered alongside the baseline reference tools by
/// ``DemoTools/register(on:root:)`` so the scripted scenarios can dispatch
/// them without bespoke `configure` closures.
enum FailureDemoTools {

    /// Names of the tools registered by ``register(on:)``. Mirrors
    /// ``DemoTools/baselineNames`` so the scenario runner's reset-to-defaults
    /// path drops them between scenarios.
    static let names: [String] = [
        "fakeRateLimited",
        "fakeMCPLookup"
    ]

    /// Registers the failure-path tools on `registry`.
    @MainActor
    static func register(on registry: ToolRegistry) {
        registry.register(FakeRateLimitedTool.makeExecutor())
        registry.register(FakeMCPLookupTool.makeExecutor())
    }
}

// MARK: - FakeRateLimitedTool

/// Stateful demo tool that fails with `.rateLimited` on the first call and
/// succeeds on every subsequent call.
///
/// Used by the `rate-limited-retry` scenario to demonstrate the orchestrator
/// feeding a transient error back to the model so it can retry within the
/// same turn (governed by `GenerationConfig.maxToolIterations`).
enum FakeRateLimitedTool {

    struct Args: Decodable, Sendable {
        let query: String
    }

    struct Result: Encodable, Sendable {
        let result: String
        let attempt: Int
    }

    static func makeExecutor() -> any ToolExecutor {
        let definition = ToolDefinition(
            name: "fakeRateLimited",
            description: "Fetches a fact about the supplied query. Occasionally rate-limits — when it returns a rateLimited error, retry the same call to recover.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Subject to look up.")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        )
        return RateLimitedExecutor(definition: definition, state: CallState())
    }

    /// Mutable counter shared between calls. Wrapped in an actor so the demo
    /// tool stays Sendable without leaning on locks.
    actor CallState {
        private var calls: Int = 0

        /// Returns the post-increment call count (1-indexed).
        func recordCall() -> Int {
            calls += 1
            return calls
        }
    }

    private struct RateLimitedExecutor: ToolExecutor {
        let definition: ToolDefinition
        let state: CallState

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            // Validate arguments first so malformed input always returns the
            // canonical `.invalidArguments` ErrorKind, regardless of which
            // attempt this is. Otherwise the first call would mask decode
            // failures behind `.rateLimited`, and later calls would throw
            // (which `ToolRegistry` classifies as `.permanent`) — neither
            // matches the "invalid args" demo story.
            let args: Args
            do {
                let data = try JSONEncoder().encode(arguments)
                args = try JSONDecoder().decode(Args.self, from: data)
            } catch {
                return ToolResult(
                    callId: "",
                    content: "invalid arguments: \(error.localizedDescription)",
                    errorKind: .invalidArguments
                )
            }

            let attempt = await state.recordCall()
            if attempt == 1 {
                return ToolResult(
                    callId: "",
                    content: "rate limit exceeded — retry shortly",
                    errorKind: .rateLimited
                )
            }

            let result = Result(
                result: "Lookup for '\(args.query)' succeeded.",
                attempt: attempt
            )
            let encoded = try JSONEncoder().encode(result)
            return ToolResult(
                callId: "",
                content: String(data: encoded, encoding: .utf8) ?? "",
                errorKind: nil
            )
        }
    }
}

// MARK: - FakeMCPLookupTool

/// Demo tool that always fails with `.transient`, simulating an MCP transport
/// failure (server unreachable, tool not found, etc.).
///
/// TODO: replace with MCPError mapping once PR-E (`MCPErrorMapping`) merges.
/// The PR-E follow-up will swap this for a real MCP tool source whose
/// transport error is mapped through the canonical mapping helper, but the
/// scenario must build and run on the current `main` branch — emitting a
/// hand-rolled `.transient` keeps the demo functional in the meantime.
enum FakeMCPLookupTool {

    struct Args: Decodable, Sendable {
        let path: String
    }

    static func makeExecutor() -> any ToolExecutor {
        let definition = ToolDefinition(
            name: "fakeMCPLookup",
            description: "Looks up a path on a remote MCP service. The remote server is currently unreachable in the demo — call once and report the failure rather than looping.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Resource path on the MCP service.")
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        )
        return MCPLookupExecutor(definition: definition)
    }

    private struct MCPLookupExecutor: ToolExecutor {
        let definition: ToolDefinition

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            // TODO: replace with MCPError mapping once PR-E merges. Until then
            // we emit `.transient` directly so the scenario shows the
            // orchestrator's "tool failed, here's the error context" path
            // without depending on PR-E's not-yet-landed `MCPErrorMapping`.
            return ToolResult(
                callId: "",
                content: "MCP transport failure: connection refused",
                errorKind: .transient
            )
        }
    }
}
