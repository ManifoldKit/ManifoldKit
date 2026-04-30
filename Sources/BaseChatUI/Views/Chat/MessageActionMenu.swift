import SwiftUI
import BaseChatRuntime
import BaseChatInference

/// A view modifier that attaches a context menu to a message bubble.
///
/// Provides copy, edit (user messages only), and regenerate (assistant messages
/// only) actions. Uses platform-appropriate clipboard APIs.
public struct MessageActionMenuModifier: ViewModifier {

    public let message: ChatMessageRecord
    public let viewModel: ChatViewModel

    @State private var isEditing: Bool = false
    @State private var editText: String = ""

    public init(message: ChatMessageRecord, viewModel: ChatViewModel) {
        self.message = message
        self.viewModel = viewModel
    }

    public func body(content: Content) -> some View {
        content
            .contextMenu {
                if viewModel.isMessagePinned(id: message.id) {
                    unpinButton
                } else {
                    pinButton
                }

                copyButton

                if message.role == .user {
                    editButton
                }

                if message.role == .assistant {
                    regenerateButton
                }
            }
            .sheet(isPresented: $isEditing) {
                editSheet
            }
    }

    // MARK: - Context Menu Items

    private var pinButton: some View {
        Button {
            Task { await viewModel.pinMessage(id: message.id) }
        } label: {
            Label("Pin", systemImage: "pin")
        }
    }

    private var unpinButton: some View {
        Button {
            Task { await viewModel.unpinMessage(id: message.id) }
        } label: {
            Label("Unpin", systemImage: "pin.slash")
        }
    }

    private var copyButton: some View {
        Button {
            copyToClipboard(message.content)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    private var editButton: some View {
        Button {
            editText = message.content
            isEditing = true
        } label: {
            Label("Edit", systemImage: "pencil")
        }
    }

    private var regenerateButton: some View {
        Button {
            Task {
                await viewModel.regenerateLastResponse()
            }
        } label: {
            Label("Regenerate", systemImage: "arrow.counterclockwise")
        }
    }

    // MARK: - Edit Sheet

    private var editSheet: some View {
        NavigationStack {
            TextEditor(text: $editText)
                .font(.body)
                .padding()
                .navigationTitle("Edit Message")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isEditing = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let newContent = editText
                            isEditing = false
                            Task {
                                await viewModel.editMessage(message.id, newContent: newContent)
                            }
                        }
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Clipboard

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - View Extension

extension View {
    /// Attaches a context menu with message actions (copy, edit, regenerate).
    public func messageActionMenu(message: ChatMessageRecord, viewModel: ChatViewModel) -> some View {
        modifier(MessageActionMenuModifier(message: message, viewModel: viewModel))
    }
}

#Preview("Message Action Menu") {
    Text("Long press me for actions")
        .padding()
        .messageActionMenu(
            message: ChatMessageRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                role: .user,
                content: "Hello, world!",
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ),
            viewModel: ChatViewModel()
        )
}
