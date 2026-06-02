import Foundation
import ManifoldRuntime
import ManifoldInference
#if CloudSaaS
import ManifoldCloudCore
#endif

#if CloudSaaS
/// SessionToolSource that exposes a `search_web` tool backed by a live
/// search-enabled chat completion endpoint.
///
/// Configure with your provider's base URL and a ``TokenProvider`` for auth:
/// ```swift
/// let searchSource = WebSearchToolSource(
///     baseURL: "https://api.x.ai/v1",
///     tokenProvider: myProvider
/// )
/// await bootstrap.addToolSources([searchSource])
/// ```
@MainActor
public final class WebSearchToolSource: SessionToolSource {

    private let baseURL: String
    private let tokenProvider: any TokenProvider
    private let model: String
    private let urlSession: URLSession

    public init(baseURL: String, tokenProvider: any TokenProvider, model: String = "grok-4.3", session: URLSession = URLSessionFactory.ephemeral()) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.model = model
        self.urlSession = session
    }

    nonisolated public func toolDefinitions(for session: ChatSessionRecord) async -> [ToolDefinition] {
        [ToolDefinition(
            name: "search_web",
            description: "Search the web for current information. Use for recent events, news, prices, or facts that may have changed.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("The search query")])
                ]),
                "required": .array([.string("query")])
            ])
        )]
    }

    nonisolated public func resolve(toolName: String, arguments: String, session: ChatSessionRecord) async throws -> ToolResult {
        guard toolName == "search_web",
              let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? String, !query.isEmpty
        else { return ToolResult(callId: toolName, content: "Invalid arguments", errorKind: .invalidArguments) }

        let token = try await tokenProvider.token()
        guard let endpointURL = URL(string: "\(baseURL)/chat/completions") else {
            return ToolResult(callId: toolName, content: "Invalid baseURL: \(baseURL)", errorKind: .invalidArguments)
        }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": query]],
            "search_parameters": ["mode": "on"],
            "max_tokens": 1000
        ])

        let (responseData, response) = try await urlSession.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode
        guard httpStatus == 200 else {
            return ToolResult(callId: toolName, content: "Search failed (HTTP \(httpStatus.map(String.init) ?? "unknown"))", errorKind: .transient)
        }
        let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        let content = ((responseJSON?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? "No results"
        return ToolResult(callId: toolName, content: content)
    }
}
#endif
