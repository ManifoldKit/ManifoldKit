import Foundation

/// Installs structured conversation history on backends that opt in, and
/// provides the legacy flattened history shape for text-only consumers.
enum GenerationHistoryInstaller {
    /// Flattens ``StructuredMessage`` to the legacy `(role, content)` shape
    /// for the genuine string-only ``ConversationHistoryReceiver`` seam.
    ///
    /// This projection is **lossy by design**: it carries only `.text` parts.
    /// Thinking parts are dropped because they would either bloat the prompt
    /// with provider-internal reasoning or fail validation on the
    /// non-Anthropic providers that don't accept replayed thinking; tool-call /
    /// tool-result / image parts are dropped because the string seam cannot
    /// represent them. That drop is *intentional redundancy*, not the
    /// tool-rendering bug fixed in #1909: backends that need the structured
    /// shape adopt ``StructuredHistoryReceiver`` and receive the unflattened
    /// form *first* (see ``installHistory(on:structuredMessages:)``), so the
    /// flattened form is only a fallback for backends that inspect strings.
    ///
    /// - Important: This is **not** the projection used to render a prompt for a
    ///   templateless model. The prompt-render fallback in ``PromptRenderer``
    ///   uses ``toolAwareProjection(_:)`` so tool parts reach the prompt text.
    static func flatten(_ messages: [StructuredMessage]) -> [(role: String, content: String)] {
        messages.map { (role: $0.role, content: $0.textContent) }
    }

    /// Projects ``StructuredMessage`` to `(role, content)` for the enum-fallback
    /// *prompt-render* path, folding tool-call / tool-result parts into the text
    /// so they are NOT dropped (#1909).
    ///
    /// The hand-rolled ``PromptTemplate`` formatters only consume the textual
    /// `content`, so a templateless (or unrenderable-template) model that drove
    /// the fallback through ``flatten(_:)`` lost every tool call and tool result
    /// — exactly the silent tool-drop #1909 fixes. This projection renders those
    /// parts into a compact textual form the model can read:
    ///
    /// - `.toolCall` → `[tool_call] <name>(<arguments JSON>)`
    /// - `.toolResult` → `[tool_result] (<callId>) <content>` (errors flagged as `[tool_error]`)
    ///
    /// The `callId` is included so that parallel tool results can be paired
    /// back to their originating calls — without it a model receiving N bare
    /// result lines has no identifier to match each result to its call.
    ///
    /// Text parts are preserved verbatim; thinking and image/audio parts are
    /// still dropped (a text prompt cannot carry them — image gating happens
    /// upstream in ``GenerationQueue``). When a turn carries both text and tool
    /// parts they are joined with newlines in original part order.
    static func toolAwareProjection(
        _ messages: [StructuredMessage]
    ) -> [(role: String, content: String)] {
        messages.map { message in
            var pieces: [String] = []
            for part in message.parts {
                switch part {
                case .text(let text):
                    if !text.isEmpty { pieces.append(text) }
                case .toolCall(let call):
                    pieces.append("[tool_call] \(call.toolName)(\(call.arguments))")
                case .toolResult(let result):
                    let prefix = result.errorKind != nil ? "[tool_error]" : "[tool_result]"
                    // Include the callId so parallel results can be paired back
                    // to their originating tool calls (#1909).
                    pieces.append("\(prefix) (\(result.callId)) \(result.content)")
                case .thinking, .image, .audio, .generatedMedia:
                    // Not representable in a text prompt; dropped (see #1909 doc).
                    break
                }
            }
            return (role: message.role, content: pieces.joined(separator: "\n"))
        }
    }

    static func containsImages(_ messages: [StructuredMessage]) -> Bool {
        messages.contains { message in
            message.parts.contains { part in
                if case .image = part { return true }
                return false
            }
        }
    }

    /// Hands history to whichever receiver protocol the backend conforms to.
    ///
    /// A backend may conform to both — ``StructuredHistoryReceiver`` is set
    /// first so a backend that needs structured access (Anthropic) gets the
    /// authoritative shape, and the flattened ``ConversationHistoryReceiver``
    /// fallback is set afterwards for backends that only inspect strings.
    static func installHistory(on backend: InferenceBackend, structuredMessages: [StructuredMessage]) {
        if let structuredReceiver = backend as? StructuredHistoryReceiver {
            structuredReceiver.setStructuredHistory(structuredMessages)
        }
        if let historyReceiver = backend as? ConversationHistoryReceiver {
            historyReceiver.setConversationHistory(flatten(structuredMessages))
        }
    }
}
