import Foundation
import ManifoldRuntime
import ManifoldInference

/// A ``SessionToolSource`` that advertises a ``generate_image`` tool to the
/// language model. Install it via
/// ``ConversationRuntime/updateSessionToolSources(_:)`` after wiring an
/// ``ImageGenerationRuntime`` into the chat view model.
///
/// When the model calls ``generate_image``, this source forwards the request
/// to ``ChatViewModel/generateImage(prompt:config:)`` so the generated image
/// appears inline as a chat message without any user interaction.
@MainActor
public final class ImageGenerationToolSource: SessionToolSource {

    private let viewModel: ChatViewModel

    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    nonisolated public func toolDefinitions(
        for session: ChatSession
    ) async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "generate_image",
                description: "Generate an image from a text description and insert it into the conversation. Use this when the user asks you to create, draw, make, or show them an image.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "prompt": .object([
                            "type": .string("string"),
                            "description": .string("A detailed description of the image to generate")
                        ])
                    ]),
                    "required": .array([.string("prompt")])
                ])
            )
        ]
    }

    nonisolated public func resolve(
        toolName: String,
        arguments: String,
        session: ChatSession
    ) async throws -> ToolResult {
        guard toolName == "generate_image" else {
            return ToolResult(callId: toolName, content: "Unknown tool: \(toolName)", errorKind: .unknownTool)
        }
        guard
            let data = arguments.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let prompt = json["prompt"] as? String,
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ToolResult(callId: toolName, content: "Expected a non-empty \"prompt\" string.", errorKind: .invalidArguments)
        }
        do {
            let messageID = try await viewModel.generateImage(prompt: prompt, config: ImageGenerationConfig())
            return ToolResult(callId: toolName, content: "Image generation started (id: \(messageID)). It will appear in the conversation shortly.")
        } catch {
            return ToolResult(callId: toolName, content: "Image generation failed: \(error.localizedDescription)", errorKind: .transient)
        }
    }
}
