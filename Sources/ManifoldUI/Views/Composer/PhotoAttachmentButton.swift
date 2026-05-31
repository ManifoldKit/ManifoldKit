#if os(iOS)
@preconcurrency import PhotosUI
import SwiftUI
import ManifoldInference

/// A compose-bar button that lets users attach a photo from their library
/// to the current message draft. Reads ``ChatViewModel`` from the SwiftUI
/// environment.
///
/// The selected image is staged via ``ChatViewModel/stageAttachment(_:)``
/// as a ``MessagePart/image(data:mimeType:placeholderHash:)`` part and
/// sent along with the next user message.
///
/// Pair with ``VoiceComposerAccessory`` or use standalone as the
/// `composerAccessory` argument to ``ChatView``.
///
/// ## Usage
///
/// ```swift
/// // As sole composerAccessory:
/// ChatView(showModelManagement: $show, composerAccessory: {
///     PhotoAttachmentButton()
/// })
///
/// // Alongside voice:
/// ChatView(showModelManagement: $show, composerAccessory: {
///     HStack {
///         PhotoAttachmentButton()
///         VoiceComposerAccessory(controller: controller)
///     }
/// })
/// ```
public struct PhotoAttachmentButton: View {
    @Environment(ChatViewModel.self) private var viewModel
    @State private var photoItem: PhotosPickerItem?

    public init() {}

    /// Returns `true` when there is already an image part staged on the draft.
    private var hasImageStaged: Bool {
        viewModel.stagedAttachments.contains {
            if case .image = $0 { return true }
            return false
        }
    }

    public var body: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(hasImageStaged ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasImageStaged ? "Photo attached" : "Attach photo")
        .help(hasImageStaged ? "Photo attached" : "Attach photo from library")
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            loadPhoto(from: newItem)
        }
    }

    // MARK: - Private helpers

    /// Loads image data from `item` and stages it via the view model.
    private func loadPhoto(from item: PhotosPickerItem) {
        let mimeType = resolvedMIMEType(for: item)
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                viewModel.stageAttachment(.image(data: data, mimeType: mimeType))
            } catch {
                viewModel.surfaceError(error, kind: .configuration, context: "attaching photo")
            }
        }
    }

    /// Infers the best MIME type from the item's `supportedContentTypes`, falling
    /// back to `image/jpeg` when no recognized type is found.
    private func resolvedMIMEType(for item: PhotosPickerItem) -> String {
        for contentType in item.supportedContentTypes {
            if let mime = contentType.preferredMIMEType, mime.hasPrefix("image/") {
                return mime
            }
        }
        return "image/jpeg"
    }

    // MARK: - Public

    /// Removes all staged image attachments from the current draft.
    ///
    /// Delegates to ``ChatViewModel/clearStagedAttachments()``; provided as a
    /// convenience so a parent view can programmatically reset the picker state
    /// without referencing `ChatViewModel` directly.
    public func clearSelection() {
        photoItem = nil
        viewModel.clearStagedAttachments()
    }
}
#endif
