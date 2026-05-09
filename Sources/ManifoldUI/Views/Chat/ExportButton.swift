import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// Drop-in toolbar button that exports the active chat session via a
/// ``ConversationExportFormat`` and presents the system share sheet.
///
/// Reads the active session and messages off `ChatViewModel` in the
/// environment, so the button is a one-liner at the call site:
///
/// ```swift
/// .toolbar {
///     ExportButton(format: MarkdownExportFormat())
///     ExportButton(format: JSONLExportFormat())
/// }
/// ```
///
/// File generation is deferred to a user tap and the result is cached in
/// `@State`; the toolbar `body` does no disk I/O. Apps that want richer error
/// UX (banners, retry) should call ``ConversationExporter`` directly from a
/// custom button action instead of using this convenience.
public struct ExportButton<Format: ConversationExportFormat>: View {

    @Environment(ChatViewModel.self) private var viewModel

    private let format: Format
    private let label: String
    private let systemImage: String

    /// Cached export — populated by a tap, cleared after sharing.
    /// Keeping this in `@State` (not recomputed in `body`) is what prevents
    /// the export pipeline from running on every SwiftUI invalidation.
    @State private var pendingFile: PendingFile?

    /// - Parameters:
    ///   - format: The serializer. Use ``MarkdownExportFormat`` or
    ///     ``JSONLExportFormat`` for the built-in formats, or pass a custom
    ///     ``ConversationExportFormat`` from your app.
    ///   - label: Visible text on the button. Defaults to "Export".
    ///   - systemImage: SF Symbol name. Defaults to `square.and.arrow.up`.
    public init(
        format: Format,
        label: String = "Export",
        systemImage: String = "square.and.arrow.up"
    ) {
        self.format = format
        self.label = label
        self.systemImage = systemImage
    }

    public var body: some View {
        Button {
            generate()
        } label: {
            Label(label, systemImage: systemImage)
        }
        .disabled(!hasExportableSession)
        // `.sheet(item:)` only fires when `pendingFile` becomes non-nil — the
        // file is written exactly once per tap. Auto-dismiss clears the
        // state so the next tap regenerates with current messages.
        .sheet(item: $pendingFile, onDismiss: cleanupPendingFile) { file in
            ShareLink(
                item: file.shareable.url,
                subject: Text(viewModel.activeSession?.title ?? "Chat"),
                message: Text("Exported from \(ManifoldConfiguration.shared.appName)"),
                preview: SharePreview(file.shareable.suggestedFilename)
            ) {
                Label("Share \(file.shareable.suggestedFilename)", systemImage: systemImage)
            }
            .padding()
        }
    }

    private var hasExportableSession: Bool {
        viewModel.activeSession != nil && !viewModel.messages.isEmpty
    }

    private func generate() {
        guard let session = viewModel.activeSession else { return }
        let messages = viewModel.messages
        guard !messages.isEmpty else { return }
        do {
            let file = try ConversationExporter.export(
                session: session,
                messages: messages,
                format: format
            )
            pendingFile = PendingFile(shareable: file)
        } catch {
            Log.ui.error("Conversation export failed: \(error.localizedDescription)")
        }
    }

    private func cleanupPendingFile() {
        // The exporter writes into a unique subdirectory of `tmp`; remove the
        // whole directory so we don't leak the file once the share sheet
        // closes. Best-effort: filesystem cleanup never blocks the user.
        if let url = pendingFile?.shareable.url {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        pendingFile = nil
    }

    /// Wraps ``ShareableFile`` with `Identifiable` so it drives `.sheet(item:)`.
    private struct PendingFile: Identifiable {
        let id = UUID()
        let shareable: ShareableFile
    }
}
