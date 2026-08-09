import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// A view modifier that attaches a context menu to a message bubble.
///
/// Surfaces per-message actions on macOS via secondary-tap (right-click) and
/// on iOS / iPadOS via long-press. Default actions cover pin, copy, edit
/// (user messages only), regenerate (assistant messages only), branch from
/// here, and delete.
///
/// Hosts extend the menu by passing a `@ViewBuilder` closure to
/// ``SwiftUICore/View/messageActionMenu(message:viewModel:contextMenuItems:)``;
/// the extra items render after the default set.
package struct MessageActionMenuModifier<ExtraItems: View>: ViewModifier {

    package let message: ChatMessage
    package let viewModel: ChatViewModel
    private let extraItems: (ChatMessage) -> ExtraItems

    @State private var isEditing: Bool = false
    @State private var editText: String = ""

    package init(
        message: ChatMessage,
        viewModel: ChatViewModel,
        @ViewBuilder extraItems: @escaping (ChatMessage) -> ExtraItems
    ) {
        self.message = message
        self.viewModel = viewModel
        self.extraItems = extraItems
    }

    package func body(content: Content) -> some View {
        content
            .contextMenu {
                if viewModel.isMessagePinned(id: message.id) {
                    unpinButton
                } else {
                    pinButton
                }

                copyButton

                if message.role == .user {
                    if message.status == .failed {
                        retryButton
                    }
                    editButton
                }

                if message.role == .assistant {
                    regenerateButton
                }

                branchButton

                Divider()

                deleteButton

                extraItems(message)
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
        .accessibilityIdentifier("message-action-pin")
    }

    private var unpinButton: some View {
        Button {
            Task { await viewModel.unpinMessage(id: message.id) }
        } label: {
            Label("Unpin", systemImage: "pin.slash")
        }
        .accessibilityIdentifier("message-action-unpin")
    }

    private var copyButton: some View {
        Button {
            ClipboardWriter.copy(message.content)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .accessibilityIdentifier("message-action-copy")
    }

    private var retryButton: some View {
        Button {
            Task { await viewModel.retrySend(message.id) }
        } label: {
            Label("Retry", systemImage: "arrow.clockwise")
        }
        .accessibilityLabel("Retry sending message")
        .accessibilityHint("Re-attempts delivery of this failed message")
        .accessibilityIdentifier("message-action-retry")
    }

    private var editButton: some View {
        Button {
            editText = message.content
            isEditing = true
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        .accessibilityIdentifier("message-action-edit")
    }

    private var regenerateButton: some View {
        Button {
            Task {
                await viewModel.regenerateLastResponse()
            }
        } label: {
            Label("Regenerate", systemImage: "arrow.counterclockwise")
        }
        .accessibilityIdentifier("message-action-regenerate")
    }

    private var branchButton: some View {
        Button {
            Task { await viewModel.branch(from: message.id) }
        } label: {
            Label("Branch from here", systemImage: "arrow.triangle.branch")
        }
        .accessibilityIdentifier("message-action-branch")
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            Task { await viewModel.deleteMessage(id: message.id) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .accessibilityIdentifier("message-action-delete")
    }

    // MARK: - Edit Sheet

    private var editSheet: some View {
        NavigationStack {
            TextEditor(text: $editText)
                .font(.body)
                .padding()
                .accessibilityIdentifier("message-edit-text-editor")
                .navigationTitle("Edit Message")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isEditing = false
                        }
                        .accessibilityIdentifier("message-edit-cancel")
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
                        .accessibilityIdentifier("message-edit-save")
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - View Extension

extension View {
    /// Attaches a context menu with the default message actions (pin, copy,
    /// edit, regenerate, branch, delete).
    public func messageActionMenu(
        message: ChatMessage,
        viewModel: ChatViewModel
    ) -> some View {
        modifier(MessageActionMenuModifier(message: message, viewModel: viewModel) { _ in
            EmptyView()
        })
    }

    /// Attaches a context menu with the default message actions plus the
    /// host-supplied items rendered after the defaults.
    public func messageActionMenu<ExtraItems: View>(
        message: ChatMessage,
        viewModel: ChatViewModel,
        @ViewBuilder contextMenuItems: @escaping (ChatMessage) -> ExtraItems
    ) -> some View {
        modifier(MessageActionMenuModifier(
            message: message,
            viewModel: viewModel,
            extraItems: contextMenuItems
        ))
    }
}

#Preview("Message Action Menu") {
    Text("Long press me for actions")
        .padding()
        .messageActionMenu(
            message: ChatMessage(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                role: .user,
                content: "Hello, world!",
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ),
            viewModel: ChatViewModel()
        )
}
