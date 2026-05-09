import Foundation
import ManifoldInference

/// Deterministic HTTP-shaped tool that returns canned JSON for known fixture
/// URLs. Real network access is gated behind both a flag *and* an environment
/// variable so the default CI mode cannot touch the public internet.
public enum HttpGetFixtureTool {

    public struct Args: Decodable, Sendable {
        public let url: String
    }

    public struct Result: Encodable, Sendable {
        public let url: String
        public let status: Int
        public let body: String
    }

    /// Canned responses for fixture URLs. Use these in scenario prompts when
    /// you need the model to exercise the HTTP path without leaving the
    /// process.
    public static let fixtures: [String: String] = [
        "https://fixture.bck/weather": #"{"city":"Dublin","sky":"clear","celsius":14}"#,
        "https://fixture.bck/echo": #"{"ok":true,"message":"fixture echo"}"#
    ]

    /// - Parameter allowRealNetwork: When `true`, unknown URLs fall through to
    ///   a real `URLSession.shared.data(for:)` call — but only if the
    ///   `BCK_TOOLS_ALLOW_NETWORK` env var is also set to `1`. Double gating
    ///   prevents accidental network activity in CI.
    public static func makeExecutor(allowRealNetwork: Bool = false) -> any ToolExecutor {
        let definition = ToolDefinition(
            name: "http_get_fixture",
            description: "Fetches a canned JSON fixture for a well-known https://fixture.bck/* URL. Never hits the real internet in CI.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("HTTPS URL to fetch.")
                    ])
                ]),
                "required": .array([.string("url")])
            ])
        )
        return HttpGetFixtureExecutor(definition: definition, allowRealNetwork: allowRealNetwork)
    }

    struct HttpGetFixtureExecutor: ToolExecutor {
        let definition: ToolDefinition
        let allowRealNetwork: Bool

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            let data = try JSONEncoder().encode(arguments)
            let args = try JSONDecoder().decode(Args.self, from: data)

            if let body = fixtures[args.url] {
                return encode(Result(url: args.url, status: 200, body: body))
            }

            let envAllowed = ProcessInfo.processInfo.environment["BCK_TOOLS_ALLOW_NETWORK"] == "1"
            guard allowRealNetwork, envAllowed else {
                return ToolResult(
                    callId: "",
                    content: "URL '\(args.url)' is not a known fixture and real network access is disabled (pass --real-network and set BCK_TOOLS_ALLOW_NETWORK=1).",
                    errorKind: .permissionDenied
                )
            }

            guard let url = URL(string: args.url) else {
                return ToolResult(
                    callId: "",
                    content: "invalid URL: \(args.url)",
                    errorKind: .invalidArguments
                )
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data: data, encoding: .utf8) ?? ""
                return encode(Result(url: args.url, status: status, body: body))
            } catch {
                return ToolResult(
                    callId: "",
                    content: "network error: \(error)",
                    errorKind: .transient
                )
            }
        }

        private func encode(_ result: Result) -> ToolResult {
            do {
                let data = try JSONEncoder().encode(result)
                return ToolResult(
                    callId: "",
                    content: String(data: data, encoding: .utf8) ?? "",
                    errorKind: nil
                )
            } catch {
                return ToolResult(
                    callId: "",
                    content: "encode failed: \(error)",
                    errorKind: .permanent
                )
            }
        }
    }
}
