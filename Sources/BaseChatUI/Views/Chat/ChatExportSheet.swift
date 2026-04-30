import SwiftUI
import BaseChatRuntime
import BaseChatInference

/// Sheet for exporting the current chat session.
public struct ChatExportSheet: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFormat: ExportFormat = .markdown
    @State private var exportedText: String = ""

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Export Format", selection: $selectedFormat) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Preview") {
                    Text(exportedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: 200)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Export Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(
                        item: exportedText,
                        subject: Text(viewModel.activeSession?.title ?? "Chat"),
                        message: Text("Exported from \(BaseChatConfiguration.shared.appName)")
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(exportedText.isEmpty)
                }
            }
            .onAppear {
                updatePreview()
            }
            .onChange(of: selectedFormat) {
                updatePreview()
            }
        }
    }

    private func updatePreview() {
        exportedText = viewModel.exportChat(format: selectedFormat)
    }
}

#Preview("Export Sheet") {
    ChatExportSheet()
        .environment(ChatViewModel())
}
