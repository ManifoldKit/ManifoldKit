import SwiftUI

/// In-transcript progress card for an in-flight image/video generation
/// (`docs/UI-REFRESH-2026.md` §4A). Renders while
/// ``ChatViewModel/imageGenerationProgress`` / ``ChatViewModel/videoGenerationProgress``
/// report an incomplete entry for the hosting message; settles in place once
/// the placeholder message's `contentParts` gain the terminal
/// `.generatedMedia` part (``MessagePartsView`` stops rendering this card at
/// that point and renders the settled media instead).
///
/// Shimmer title + step/fraction bar + blurred live preview (image only —
/// video progress carries no intermediate frame) + cancel, same lifecycle
/// grammar as ``ToolInvocationView``'s running state.
struct GeneratedMediaProgressCardView: View {

    /// The two generation modalities that report progress today. Audio is a
    /// one-shot artifact with no intermediate progress event, so it never
    /// reaches this view (`ChatViewModel` has no `audioGenerationProgress`).
    enum Progress {
        /// `step`/`totalSteps` are `0` before the first progress event.
        case image(step: Int, totalSteps: Int, previewImage: Data?)
        /// `fractionComplete` is `0` while queued.
        case video(fractionComplete: Double)
    }

    @Environment(\.manifoldTheme) private var theme

    let prompt: String
    let progress: Progress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: kindSystemImage)
                    .foregroundStyle(theme.ink2)
                Text(title)
                    .font(theme.type.caption.weight(.semibold))
                    .foregroundStyle(theme.ink2)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(theme.type.caption2)
                    .foregroundStyle(theme.ink3)
                    .accessibilityIdentifier("generated-media-progress-cancel")
            }

            if let previewImage, let platformPreview = Self.decodePreview(previewImage) {
                previewImageView(platformPreview)
            }

            ProgressView(value: fractionComplete)
                .progressViewStyle(.linear)
                .tint(theme.accent)

            Text(stepLabel)
                .font(theme.type.caption2)
                .foregroundStyle(theme.ink3)
        }
        .padding(10)
        .background(theme.surface2, in: RoundedRectangle(cornerRadius: theme.shape.md))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(stepLabel)")
        .accessibilityIdentifier("generated-media-progress-\(kindLabel)")
    }

    // MARK: - Derived display state

    private var kindLabel: String {
        switch progress {
        case .image: "image"
        case .video: "video"
        }
    }

    private var kindSystemImage: String {
        switch progress {
        case .image: "photo.badge.clock"
        case .video: "video.badge.clock"
        }
    }

    private var title: String {
        switch progress {
        case .image: "Generating image…"
        case .video: "Generating video…"
        }
    }

    private var fractionComplete: Double {
        switch progress {
        case .image(let step, let totalSteps, _):
            guard totalSteps > 0 else { return 0 }
            return Double(step) / Double(totalSteps)
        case .video(let fractionComplete):
            return fractionComplete
        }
    }

    private var stepLabel: String {
        switch progress {
        case .image(let step, let totalSteps, _):
            guard totalSteps > 0 else { return "Starting…" }
            return "Step \(step) of \(totalSteps)"
        case .video(let fractionComplete):
            return "\(Int(fractionComplete * 100))%"
        }
    }

    private var previewImage: Data? {
        if case .image(_, _, let previewImage) = progress { return previewImage }
        return nil
    }

    @ViewBuilder
    private func previewImageView(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 160)
            .blur(radius: 6)
            .clipShape(RoundedRectangle(cornerRadius: theme.shape.sm))
            .accessibilityHidden(true)
    }

    #if os(iOS)
    private static func decodePreview(_ data: Data) -> Image? {
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
    }
    #elseif os(macOS)
    private static func decodePreview(_ data: Data) -> Image? {
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
    }
    #endif
}

#Preview("Image — with preview") {
    GeneratedMediaProgressCardView(
        prompt: "a lighthouse at dusk",
        progress: .image(step: 12, totalSteps: 30, previewImage: nil),
        onCancel: {}
    )
    .padding()
}

#Preview("Video") {
    GeneratedMediaProgressCardView(
        prompt: "a drone shot over the ocean",
        progress: .video(fractionComplete: 0.42),
        onCancel: {}
    )
    .padding()
}
