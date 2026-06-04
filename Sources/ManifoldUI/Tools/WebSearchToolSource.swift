import Foundation
import ManifoldRuntime
import ManifoldInference

/// A ``SessionToolSource`` that advertises a ``search_web`` tool to the
/// language model. Install it via
/// ``ConversationRuntime/updateSessionToolSources(_:)`` after wiring a
/// ``WebSearchRuntime`` into the chat view model.
///
/// When the model calls ``search_web``, this source forwards the query to
/// ``ChatViewModel/searchWeb(query:)`` and returns the result text so the
/// model can use it inside the same conversation turn. All network I/O lives
/// in the concrete `DefaultWebSearchRuntime` (in `ManifoldCloud`) — this tool
/// is a thin forwarder with no cloud or `URLSession` dependency, identical in
/// shape to ``ImageGenerationToolSource``.
@MainActor
public final class WebSearchToolSource: SessionToolSource {

    private let viewModel: ChatViewModel

    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    nonisolated public func toolDefinitions(
        for session: ChatSessionRecord
    ) async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "search_web",
                description: "Search the web for current information. Use for recent events, news, prices, or facts that may have changed.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("The search query")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            )
        ]
    }

    nonisolated public func resolve(
        toolName: String,
        arguments: String,
        session: ChatSessionRecord
    ) async throws -> ToolResult {
        guard toolName == "search_web" else {
            return ToolResult(callId: toolName, content: "Unknown tool: \(toolName)", errorKind: .unknownTool)
        }
        guard
            let data = arguments.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let query = json["query"] as? String,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ToolResult(callId: toolName, content: "Invalid arguments", errorKind: .invalidArguments)
        }
        do {
            let content = try await viewModel.searchWeb(query: query)
            return ToolResult(callId: toolName, content: content)
        } catch {
            return ToolResult(callId: toolName, content: "Search failed: \(error.localizedDescription)", errorKind: .transient)
        }
    }
}
