import SwiftUI
import ManifoldInference
#if os(iOS)
@preconcurrency import PhotosUI
#endif

/// A cross-platform compose-bar button for attaching images.
///
/// On iOS presents the Photos picker; on macOS opens a file-chooser panel
/// restricted to image UTTypes. Stages the selected image via
/// ``ChatViewModel/stageAttachment(_:)`` as a
/// `MessagePart.image(data:mimeType:placeholderHash:)` part.
///
/// Only shown when the active backend's `BackendCapabilities` indicate
/// vision support (`BackendCapabilities.supportsVision`). When vision is
/// unsupported the button is hidden.
///
/// ```swift
/// ChatView(showModelManagement: $show, composerAccessory: {
///     VisionInputButton()
/// })
/// ```
///
/// Combine with `VoiceComposerAccessory` (from `ManifoldVoice`) when your app
/// supports both modalities:
///
/// ```swift
/// ChatView(showModelManagement: $show, composerAccessory: {
///     HStack {
///         VisionInputButton()
///         VoiceComposerAccessory(controller: controller)
///     }
/// })
/// ```
///
/// > Note: On iOS, `PhotoAttachmentButton` provides equivalent functionality
/// > but is restricted to that platform. Prefer ``VisionInputButton`` for
/// > cross-platform codebases.
public struct VisionInputButton: View {
    @Environment(ChatViewModel.self) private var viewModel

    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    #endif

    private var features: ManifoldConfiguration.Features { ManifoldConfiguration.shared.features }

    public init() {}

    /// Returns `true` when there is already an image part staged on the draft.
    private var hasImageStaged: Bool {
        viewModel.stagedAttachments.contains {
            if case .image = $0 { return true }
            return false
        }
    }

    /// Whether the current backend supports vision input.
    private var isVisionSupported: Bool {
        viewModel.backendCapabilities?.supportsVision == true
    }

    public var body: some View {
        #if os(iOS)
        // PhotosPicker is PHPicker-backed and needs no usage string, so only the
        // feature flag gates it (alongside backend vision support).
        if isVisionSupported && features.showImageAttachment {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo.badge.plus")
                    .symbolVariant(.fill)
                    .font(.title2)
                    .foregroundStyle(hasImageStaged ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasImageStaged ? "Photo attached" : "Attach photo")
            .help(hasImageStaged ? "Photo attached" : "Attach image")
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                loadPhoto(from: newItem)
            }
        }
        #elseif os(macOS)
        // The macOS NSOpenPanel needs no usage string, so only the feature flag
        // gates it (alongside backend vision support).
        if isVisionSupported && features.showImageAttachment {
            Button {
                openImagePanel()
            } label: {
                Image(systemName: "photo.badge.plus")
                    .symbolVariant(.fill)
            }
            .help("Attach image")
        }
        #else
        EmptyView()
        #endif
    }

    // MARK: - Private helpers

    #if os(iOS)
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
    #endif

    #if os(macOS)
    /// Opens a system file-chooser panel restricted to image file types.
    @MainActor
    private func openImagePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .jpeg, .png, .heic, .gif, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [panel] response in
            guard response == .OK, let url = panel.url else { return }
            // Read file data off the main actor to avoid blocking the UI thread
            // on large image files, then hop back to @MainActor to stage the part.
            Task {
                do {
                    let data = try Data(contentsOf: url)
                    let mime = mimeType(for: url)
                    await MainActor.run {
                        viewModel.stageAttachment(.image(data: data, mimeType: mime))
                    }
                } catch {
                    await MainActor.run {
                        viewModel.surfaceError(error, kind: .configuration, context: "attaching image from file")
                    }
                }
            }
        }
    }

    /// Infers the MIME type from the file's path extension, falling back to
    /// `image/jpeg` for unrecognised extensions.
    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "heic":        return "image/heic"
        case "heif":        return "image/heif"
        case "bmp":         return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        default:            return "image/jpeg"
        }
    }
    #endif
}
