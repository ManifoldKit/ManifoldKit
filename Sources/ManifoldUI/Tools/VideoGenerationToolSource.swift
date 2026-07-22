import Foundation
import ManifoldRuntime
import ManifoldInference

/// A ``SessionToolSource`` that advertises a ``generate_video`` tool to the
/// language model. Install it via
/// ``ConversationRuntime/updateSessionToolSources(_:)`` after wiring a
/// ``VideoGenerationRuntime`` into the chat view model.
///
/// When the model calls ``generate_video``, this source fires-and-forgets the
/// generation via a detached `Task` so ``resolve(toolName:arguments:session:)``
/// returns immediately — video generation is long-running (~30–60 s) and must
/// not block the conversation turn executor. Progress and the completed video
/// surface through ``ChatViewModel/videoGenerationProgress`` exactly as if the
/// user had triggered generation directly.
@MainActor
public final class VideoGenerationToolSource: SessionToolSource {

    private let viewModel: ChatViewModel

    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    nonisolated public func toolDefinitions(
        for session: ChatSession
    ) async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "generate_video",
                description: "Generate a short video clip from a text description and insert it into the conversation. Use this when the user asks you to create, make, animate, or show them a video.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "prompt": .object([
                            "type": .string("string"),
                            "description": .string("A detailed description of the video to generate")
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
        guard toolName == "generate_video" else {
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
        // Preflight the same condition `generateVideo` throws
        // `ChatViewModelVideoError.notConfigured` for. Without this check the
        // model was told generation "started" even when no
        // VideoGenerationRuntime is installed — the surface stays
        // ahead-of-backend by design (#2349) but the tool result must not lie
        // about that.
        guard await viewModel.videoRuntime != nil else {
            return ToolResult(
                callId: toolName,
                content: "Video generation is not configured in this build. There is no video backend wired up, so this request cannot be started.",
                errorKind: .permanent
            )
        }
        // Fire-and-forget: video generation is long-running; resolve returns
        // immediately so the conversation turn is not blocked while the backend
        // processes the request. The generated video and progress updates surface
        // through ChatViewModel.videoGenerationProgress.
        Task { @MainActor in
            do {
                try await viewModel.generateVideo(prompt: prompt, config: VideoGenerationConfig(duration: 5))
            } catch {
                Log.ui.warning("VideoGenerationToolSource: video generation failed: \(error)")
                viewModel.surfaceError(error, kind: .generation, context: "generating video")
            }
        }
        return ToolResult(callId: toolName, content: "Video generation started. It will appear in approximately 30–60 seconds.")
    }
}
