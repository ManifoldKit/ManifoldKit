import Foundation
import BaseChatRuntime
import BaseChatInference

// MARK: - ChatViewModel + Generation Core

extension ChatViewModel {

    /// Looks up a message by ID and applies a mutation in a single step,
    /// ensuring the index is never stale. Returns `true` if the message was found.
    @discardableResult
    func mutateMessage(id: UUID, _ body: (inout ChatMessageRecord) -> Void) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return false }
        body(&messages[idx])
        return true
    }

    /// Streams tokens from the inference service into an assistant message.
    ///
    /// Delegates to ``GenerationCoordinator/generate(into:)``.
    func generateIntoMessage(_ assistantMessage: ChatMessageRecord) async {
        await generationCoordinator.generate(into: assistantMessage)
    }

    /// Substitutes `{{key}}` tokens in `text` with values from `context`.
    ///
    /// Forwarding shim so existing call sites (e.g. tests) that reference
    /// `ChatViewModel.applySystemPromptContext` continue to compile without change.
    static func applySystemPromptContext(_ text: String, context: [String: String]) -> String {
        GenerationCoordinator.applySystemPromptContext(text, context: context)
    }
}
