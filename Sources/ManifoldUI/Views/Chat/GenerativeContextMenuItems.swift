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
    let message: ChatMessageRecord
    let viewModel: ChatViewModel

    public init(message: ChatMessageRecord, viewModel: ChatViewModel) {
        self.message = message
        self.viewModel = viewModel
    }

    // MARK: - Derived state

    /// The concatenated text content of the message, empty string if none.
    private var text: String { message.content }

    /// The first generated image in the message's content parts, if any.
    private var generatedImage: ImageMessagePayload? {
        message.contentParts.compactMap(\.generatedImageContent).first
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
                    try? await viewModel.generateImage(
                        prompt: text,
                        config: ImageGenerationConfig()
                    )
                }
            } label: {
                Label("Generate Image from This", systemImage: "photo.badge.plus")
            }
        }

        // "Generate Video from This" — text message + video runtime
        if hasText && hasVideoRuntime {
            Button {
                Task {
                    try? await viewModel.generateVideo(
                        prompt: text,
                        config: VideoGenerationConfig()
                    )
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
                    try? await viewModel.generateImage(
                        prompt: prompt,
                        config: ImageGenerationConfig()
                    )
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
                    try? await viewModel.generateVideo(
                        prompt: prompt,
                        config: VideoGenerationConfig()
                    )
                }
            } label: {
                Label("Animate as Video", systemImage: "play.rectangle.on.rectangle")
            }
        }
    }
}
