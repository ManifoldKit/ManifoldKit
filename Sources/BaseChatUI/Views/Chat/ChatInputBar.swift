import SwiftUI
import BaseChatRuntime
import BaseChatInference
import UniformTypeIdentifiers

/// The text input bar at the bottom of the chat view.
///
/// Shows a multiline text field with send/stop buttons plus an image-attachment
/// affordance when the active backend reports vision support. On compact size
/// class (iPhone), a row of quick-action pills appears above the input for
/// common prompts like "Continue" and "Describe scene".
public struct ChatInputBar: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    @FocusState private var isInputFocused: Bool
    @State private var isImageImporterPresented = false

    public init() {}

    // MARK: - Body

    private var inputPlaceholder: String {
        if viewModel.isLoading { return "Loading model…" }
        if viewModel.activeSession == nil { return "No session selected" }
        if !viewModel.isModelLoaded { return "No model loaded" }
        return "Message…"
    }

    public var body: some View {
        @Bindable var viewModel = viewModel

        VStack(spacing: 8) {
            if sizeClass == .compact {
                quickActionPills
            }

            if !viewModel.draftAttachments.isEmpty {
                draftAttachmentStrip
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(inputPlaceholder, text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isInputFocused)
                    .padding(10)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(viewModel.activeSession == nil || !viewModel.isModelLoaded || viewModel.isLoading)
                    .accessibilityLabel("Message input")

                actionButtons
            }
        }
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImageImport(result)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if viewModel.supportsImageAttachments {
                attachImageButton
            }

            if showRegenerateButton {
                Button {
                    Task {
                        await viewModel.regenerateLastResponse()
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Regenerate last response")
                .help("Regenerate last response")
            }

            sendOrStopButton
        }
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        SendStopButton(
            isGenerating: viewModel.isGenerating,
            canSend: canSend,
            onSend: sendMessage,
            onStop: { viewModel.stopGeneration() }
        )
    }

    private var attachImageButton: some View {
        Button {
            isImageImporterPresented = true
        } label: {
            Image(systemName: "paperclip.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!canAttachImage)
        .accessibilityLabel("Attach image")
        .help("Attach image")
    }

    // MARK: - Quick Action Pills

    private var quickActionPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickActionPill("Continue") {
                    sendQuickAction("Continue")
                }
                quickActionPill("Summarize") {
                    sendQuickAction("Summarize")
                }
                quickActionPill("Explain more") {
                    sendQuickAction("Explain more")
                }
                quickActionPill("Give an example") {
                    sendQuickAction("Give an example")
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func quickActionPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.fill.tertiary, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.activeSession == nil || !viewModel.isModelLoaded || viewModel.isGenerating || viewModel.isLoading)
        .accessibilityLabel(title)
        .accessibilityHint("Sends \"\(title)\" as a message")
    }

    // MARK: - Helpers

    private var canSend: Bool {
        viewModel.activeSession != nil
        && viewModel.isModelLoaded
        && !viewModel.isGenerating
        && !viewModel.isLoading
        && viewModel.hasDraftContent
    }

    private var canAttachImage: Bool {
        viewModel.activeSession != nil
        && viewModel.isModelLoaded
        && !viewModel.isGenerating
        && !viewModel.isLoading
    }

    private var showRegenerateButton: Bool {
        !viewModel.isGenerating
        && !viewModel.messages.isEmpty
        && viewModel.messages.last?.role == .assistant
    }

    private func sendMessage() {
        guard canSend else { return }
        Task {
            await viewModel.sendMessage()
        }
    }

    private func sendQuickAction(_ text: String) {
        viewModel.inputText = text
        Task {
            await viewModel.sendMessage()
        }
    }

    @ViewBuilder
    private var draftAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.draftAttachments.enumerated()), id: \.offset) { index, part in
                    draftAttachmentPreview(for: part, at: index)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func draftAttachmentPreview(for part: MessagePart, at index: Int) -> some View {
        if case let .image(data, _) = part {
            ZStack(alignment: .topTrailing) {
                draftThumbnail(data: data)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Button {
                    viewModel.removeDraftAttachment(id: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white, .black.opacity(0.7))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove attachment")
            }
            .padding(.trailing, 4)
        }
    }

    @ViewBuilder
    private func draftThumbnail(data: Data) -> some View {
        #if os(iOS)
        if let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        }
        #elseif os(macOS)
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        }
        #endif
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Resolve the MIME type synchronously while the security-scoped
            // resource is open — resourceValues is a fast metadata-only call.
            // The actual file read is dispatched to a background task so it
            // never blocks the main thread on large images.
            let accessed = url.startAccessingSecurityScopedResource()
            let mimeType: String
            do {
                mimeType = try resolvedImageMIMEType(for: url)
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                viewModel.surfaceError(error, kind: .configuration, context: "attaching image")
                return
            }

            // Capture everything needed by the background task; the
            // security-scoped resource remains open until the task releases it.
            let capturedURL = url
            let capturedMIMEType = mimeType
            let capturedAccessed = accessed
            Task {
                defer {
                    if capturedAccessed { capturedURL.stopAccessingSecurityScopedResource() }
                }
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: capturedURL)
                    }.value
                    viewModel.stageDraftAttachment(.image(data: data, mimeType: capturedMIMEType))
                } catch {
                    viewModel.surfaceError(error, kind: .configuration, context: "attaching image")
                }
            }

        case .failure(let error):
            viewModel.surfaceError(error, kind: .configuration, context: "attaching image")
        }
    }

    private func resolvedImageMIMEType(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.contentTypeKey])
        let contentType = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        guard let contentType,
              contentType.conforms(to: .image),
              let mimeType = contentType.preferredMIMEType else {
            throw InferenceError.inferenceFailure("Unsupported image attachment type.")
        }
        return mimeType
    }
}

// MARK: - Send/Stop Button

/// The primary send-or-stop button rendered at the trailing edge of the chat
/// input bar. Extracted as a standalone view so its accessibility contract can
/// be inspected in unit tests without mounting a full `ChatViewModel`.
struct SendStopButton: View {

    /// Accessibility label used while the assistant is generating a response.
    static let stopLabel = "Stop generation"
    /// Accessibility label used when the button will send the composed message.
    static let sendLabel = "Send message"

    let isGenerating: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    init(
        isGenerating: Bool,
        canSend: Bool,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.isGenerating = isGenerating
        self.canSend = canSend
        self.onSend = onSend
        self.onStop = onStop
    }

    var body: some View {
        if isGenerating {
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.stopLabel)
            .help(Self.stopLabel)
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Color.accentColor : Color.gray)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Self.sendLabel)
            .help("\(Self.sendLabel) (Cmd+Return)")
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Spacer()
        Divider()
        ChatInputBar()
    }
    .environment(ChatViewModel())
}
