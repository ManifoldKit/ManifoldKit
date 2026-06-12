import Foundation
import XCTest
import ManifoldInference

enum DemoScenarioOllamaTestTools {
    static func makeRateLimitedExecutor() -> any ToolExecutor {
        FakeRateLimitedTool.makeExecutor()
    }

    static func makeMCPLookupExecutor() -> any ToolExecutor {
        FakeMCPLookupTool.makeExecutor()
    }

    static func makeMCPEchoExecutor() -> any ToolExecutor {
        struct Args: Decodable, Sendable {
            let message: String
        }
        struct Result: Encodable, Sendable {
            let echoed: String
            let server: String
        }

        return TypedToolExecutor<Args, Result>(
            definition: ToolDefinition(
                name: "everything__echo",
                description: "Echoes the supplied message through the connected demo MCP server.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "message": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("message")])
                ])
            )
        ) { args in
            Result(echoed: args.message, server: "demo-everything")
        }
    }

    static func makeComposeEmailExecutor() -> any ToolExecutor {
        struct Args: Decodable, Sendable {
            let to: String
            let subject: String
            let body: String
        }
        struct Result: Encodable, Sendable {
            let draftId: String
            let summary: String
        }

        return TypedToolExecutor<Args, Result>(
            definition: ToolDefinition(
                name: "compose_email",
                description: "Creates an email draft. Include recipient, subject, and full body.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "to": .object(["type": .string("string")]),
                        "subject": .object(["type": .string("string")]),
                        "body": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("to"), .string("subject"), .string("body")])
                ])
            ),
            requiresApproval: false
        ) { args in
            Result(
                draftId: "draft-701",
                summary: "Draft for \(args.to) about \(args.subject): \(args.body)"
            )
        }
    }

    static func makeMCPFilesystemReadExecutor() -> any ToolExecutor {
        struct Args: Decodable, Sendable {
            let path: String
        }
        struct Result: Encodable, Sendable {
            let path: String
            let content: String
        }

        return TypedToolExecutor<Args, Result>(
            definition: ToolDefinition(
                name: "mcp_fs_read",
                description: "Reads a file through the connected filesystem MCP server.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("path")])
                ])
            )
        ) { args in
            Result(
                path: args.path,
                content: "filesystem MCP fixture: Neptune migration complete"
            )
        }
    }
}

enum DemoScenarioOllamaAssertions {
    static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    static func assertArgumentContains(
        _ call: ToolCall,
        _ needle: String,
        result: DemoScenarioE2EResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            normalized(call.arguments).localizedCaseInsensitiveContains(normalized(needle)),
            "Expected \(call.toolName) args to contain \(needle).\n\(result.diagnostics)",
            file: file,
            line: line
        )
    }

    static func assertFinalTextContainsAny(
        _ needles: [String],
        result: DemoScenarioE2EResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            needles.contains { result.finalText.localizedCaseInsensitiveContains($0) },
            "Expected final answer to contain one of \(needles).\n\(result.diagnostics)",
            file: file,
            line: line
        )
    }

    static func assertToolResultContains(
        _ needle: String,
        trace: DemoScenarioE2EResult.ToolTrace,
        result: DemoScenarioE2EResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            trace.result.content.localizedCaseInsensitiveContains(needle),
            "Expected \(trace.call.toolName) result to contain \(needle).\n\(result.diagnostics)",
            file: file,
            line: line
        )
    }
}

private enum FakeRateLimitedTool {
    struct Args: Decodable, Sendable {
        let query: String
    }
    struct Result: Encodable, Sendable {
        let result: String
        let attempt: Int
    }

    static func makeExecutor() -> any ToolExecutor {
        RateLimitedExecutor(
            definition: ToolDefinition(
                name: "fakeRateLimited",
                description: "Fetches a fact about the supplied query. The first call returns rateLimited; retry the exact same arguments once.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            state: CallState()
        )
    }

    actor CallState {
        private var calls = 0

        func next() -> Int {
            calls += 1
            return calls
        }
    }

    private struct RateLimitedExecutor: ToolExecutor {
        let definition: ToolDefinition
        let state: CallState

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            let data = try JSONEncoder().encode(arguments)
            let args = try JSONDecoder().decode(Args.self, from: data)
            let attempt = await state.next()
            if attempt == 1 {
                return ToolResult(callId: "", content: "rate limit exceeded — retry shortly", errorKind: .rateLimited)
            }
            let encoded = try JSONEncoder().encode(Result(result: "Lookup for '\(args.query)' succeeded.", attempt: attempt))
            return ToolResult(callId: "", content: String(data: encoded, encoding: .utf8) ?? "", errorKind: nil)
        }
    }
}

private enum FakeMCPLookupTool {
    static func makeExecutor() -> any ToolExecutor {
        MCPLookupExecutor(
            definition: ToolDefinition(
                name: "fakeMCPLookup",
                description: "Looks up a remote MCP path. The demo server is unreachable; call once and report the transient failure.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("path")])
                ])
            )
        )
    }

    private struct MCPLookupExecutor: ToolExecutor {
        let definition: ToolDefinition

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            ToolResult(
                callId: "",
                content: "MCP transport failure: connection refused",
                errorKind: .transient
            )
        }
    }
}
