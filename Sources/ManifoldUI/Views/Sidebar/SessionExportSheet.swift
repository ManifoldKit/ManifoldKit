import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// Per-session export format offered by ``SessionExportSheet``.
///
/// Distinct from ``ExportFormat`` (the chat-toolbar's live but narrower
/// Markdown/plain-text-only `String` pipeline) — this enum drives the richer
/// file-based ``ConversationExporter`` pipeline, which also supports JSON.
public enum SessionExportFormatOption: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case plainText
    case json

    public var id: String { rawValue }

    /// Display text for the segmented picker.
    ///
    /// Labeled "JSONL" (not "JSON") because `.json` is backed by
    /// `JSONLExportFormat` and produces a `.jsonl` file — one JSON object per
    /// line, not a single JSON document. The enum case name stays `.json` to
    /// avoid rippling the rename through call sites; only the user-visible
    /// label needs to be honest.
    public var title: String {
        switch self {
        case .markdown: "Markdown"
        case .plainText: "Plain Text"
        case .json: "JSONL"
        }
    }

    var exportFormat: ConversationExportFormat {
        switch self {
        case .markdown: MarkdownExportFormat()
        case .plainText: PlainTextExportFormat()
        case .json: JSONLExportFormat()
        }
    }
}

/// Sheet that exports a single sidebar session to a real file via the rich
/// ``ConversationExporter`` pipeline (Markdown, Plain Text, or JSON) and
/// shares it through `ShareLink`.
///
/// Presented from ``SessionListView``'s per-row context menu. Unlike
/// ``ChatExportSheet`` — which shares a raw `String` for whichever session is
/// currently open in ``ChatViewModel`` via `ShareLink(item: String)` — this
/// sheet writes an actual file to disk and shares the file URL, so it works
/// for any session in the list, not just the active one.
public struct SessionExportSheet: View {

    @Environment(SessionManagerViewModel.self) private var sessionManager
    @Environment(\.dismiss) private var dismiss

    private let session: ChatSession

    @State private var selectedFormat: SessionExportFormatOption = .markdown
    @State private var exportedFile: ShareableFile?
    @State private var errorMessage: String?

    public init(session: ChatSession) {
        self.session = session
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Export Format", selection: $selectedFormat) {
                        ForEach(SessionExportFormatOption.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Export Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if let exportedFile {
                        ShareLink(
                            item: exportedFile.url,
                            subject: Text(session.title),
                            message: Text("Exported from \(ManifoldConfiguration.shared.appName)"),
                            preview: SharePreview(exportedFile.suggestedFilename)
                        ) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
            // Re-runs (cancelling any in-flight export) whenever the format
            // changes, and fires once on first appear — mirrors
            // `ChatExportSheet`'s `.onAppear` + `.onChange(of: selectedFormat)`
            // pair but as a single structured-concurrency task.
            .task(id: selectedFormat) {
                await performExport()
            }
            .onDisappear(perform: cleanupExportedFile)
        }
    }

    private func performExport() async {
        exportedFile = nil
        errorMessage = nil
        do {
            exportedFile = try await sessionManager.exportSession(session, format: selectedFormat.exportFormat)
        } catch {
            errorMessage = "Failed to export chat: \(error.localizedDescription)"
            Log.ui.error(
                "SessionExportSheet: export failed for session \(session.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Best-effort temp-file cleanup mirroring ``ExportButton``'s pattern —
    /// filesystem cleanup never blocks the user, and `ConversationExporter`
    /// writes into a unique per-export subdirectory of `tmp`, so removing the
    /// parent directory is sufficient.
    private func cleanupExportedFile() {
        if let url = exportedFile?.url {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
}

#Preview("Session Export Sheet") {
    SessionExportSheet(session: ChatSession(id: UUID(), title: "Preview Chat"))
        .environment(SessionManagerViewModel())
}
