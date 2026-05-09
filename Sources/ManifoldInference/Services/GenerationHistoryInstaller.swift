import Foundation

/// Installs structured conversation history on backends that opt in, and
/// provides the legacy flattened history shape for text-only consumers.
enum GenerationHistoryInstaller {
    /// Flattens ``StructuredMessage`` to the legacy `(role, content)` shape
    /// for backends and helpers that operate on plain strings.
    ///
    /// Thinking parts are dropped because they would either bloat the prompt
    /// with provider-internal reasoning or fail validation on the
    /// non-Anthropic providers that don't accept replayed thinking.
    /// ``StructuredHistoryReceiver`` adopters read the unflattened form
    /// directly to preserve thinking signatures.
    static func flatten(_ messages: [StructuredMessage]) -> [(role: String, content: String)] {
        messages.map { (role: $0.role, content: $0.textContent) }
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
