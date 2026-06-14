import SwiftUI
import ManifoldInference

/// Context-menu items for a chat message bubble that expose generation actions
/// when the relevant runtimes are configured.
///
/// Pass this to ``ChatView``'s `contextMenuItems` parameter:
/// ```swift
/// ChatView(showModelManagement: $show) { message in
///     GenerativeContextMenuItems(message: message, viewModel: viewModel)
/// }
/// ```
///
/// Items shown:
/// - **Generate Image from This** — when the message has text content and an
///   ``ImageGenerationRuntime`` is configured on the view model.
/// - **Generate Video from This** — when the message has text content and a
///   ``VideoGenerationRuntime`` is configured.
/// - **Remix Image** — when the message contains a generated image part
///   and an ``ImageGenerationRuntime`` is configured.
/// - **Animate as Video** — when the message contains a generated image
///   and a ``VideoGenerationRuntime`` is configured.
public struct GenerativeContextMenuItems: View {
    let message: ChatMessage
    let viewModel: ChatViewModel

    public init(message: ChatMessage, viewModel: ChatViewModel) {
        self.message = message
        self.viewModel = viewModel
    }

    // MARK: - Derived state

    /// The concatenated text content of the message, empty string if none.
    private var text: String { message.content }

    /// The first generated image in the message's content parts, if any.
    private var generatedImage: GeneratedMediaPayload? {
        message.contentParts
            .compactMap(\.generatedMediaContent)
            .first { $0.kind == .image }
    }

    // MARK: - Body

    public var body: some View {
        let hasText = !text.isEmpty
        let hasImage = generatedImage != nil
        let hasImageRuntime = viewModel.imageRuntime != nil
        let hasVideoRuntime = viewModel.videoRuntime != nil

        // "Generate Image from This" — text message + image runtime
        if hasText && hasImageRuntime {
            Button {
                Task {
                    do {
                        try await viewModel.generateImage(
                            prompt: text,
                            config: ImageGenerationConfig()
                        )
                    } catch {
                        Log.ui.warning("GenerativeContextMenuItems: image generation failed: \(error)")
                    }
                }
            } label: {
                Label("Generate Image from This", systemImage: "photo.badge.plus")
            }
        }

        // "Generate Video from This" — text message + video runtime
        if hasText && hasVideoRuntime {
            Button {
                Task {
                    do {
                        try await viewModel.generateVideo(
                            prompt: text,
                            config: VideoGenerationConfig()
                        )
                    } catch {
                        Log.ui.warning("GenerativeContextMenuItems: video generation failed: \(error)")
                    }
                }
            } label: {
                Label("Generate Video from This", systemImage: "video.badge.plus")
            }
        }

        // "Remix Image" — message contains a generated image + image runtime
        if hasImage && hasImageRuntime {
            Button {
                let prompt = generatedImage?.prompt ?? text
                Task {
                    do {
                        try await viewModel.generateImage(
                            prompt: prompt,
                            config: ImageGenerationConfig()
                        )
                    } catch {
                        Log.ui.warning("GenerativeContextMenuItems: image remix failed: \(error)")
                    }
                }
            } label: {
                Label("Remix Image", systemImage: "arrow.triangle.2.circlepath")
            }
        }

        // "Animate as Video" — message contains a generated image + video runtime
        if hasImage && hasVideoRuntime {
            Button {
                let prompt = generatedImage?.prompt ?? text
                Task {
                    do {
                        try await viewModel.generateVideo(
                            prompt: prompt,
                            config: VideoGenerationConfig()
                        )
                    } catch {
                        Log.ui.warning("GenerativeContextMenuItems: video animation failed: \(error)")
                    }
                }
            } label: {
                Label("Animate as Video", systemImage: "play.rectangle.on.rectangle")
            }
        }
    }
}
