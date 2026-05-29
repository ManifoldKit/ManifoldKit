import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ChatViewModel + Generation Helpers

// File-private top-level — nonisolated, initialized once, thread-safe.
// Kept outside the @MainActor-isolated `ChatViewModel` so that the
// nonisolated `applySystemPromptContext` static helper can access it
// without a Swift 6 actor-isolation warning.
private let _systemPromptContextRegex: NSRegularExpression = {
    // Force-unwrap is safe: the pattern is a compile-time constant with no user input.
    try! NSRegularExpression(pattern: #"\{\{(\w+)\}\}"#, options: [])
}()

extension ChatViewModel {

    /// Looks up a message by ID and applies a mutation in a single step,
    /// ensuring the index is never stale. Returns `true` if the message was found.
    @discardableResult
    func mutateMessage(id: UUID, _ body: (inout ChatMessageRecord) -> Void) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return false }
        body(&messages[idx])
        return true
    }

    /// Resolves the prompt to send to the runtime: trims, returns `nil` for
    /// the empty case so the runtime treats "no system prompt" identically
    /// regardless of input shape, and substitutes `{{key}}` tokens against
    /// ``ChatViewModel/systemPromptContext``.
    func effectiveSystemPrompt() -> String? {
        guard !systemPrompt.isEmpty else { return nil }
        return Self.applySystemPromptContext(systemPrompt, context: systemPromptContext)
    }

    /// Suspends until a runtime turn reaches its per-turn terminal outcome.
    ///
    /// Live token/thinking/message mutations still flow through the runtime
    /// event drain; this completion path uses the turn handle so callers are
    /// not coupled to the global event stream's terminal event ordering.
    func awaitTurnCompletion(_ handle: ConversationTurnHandle) async {
        await generationCoordinator.awaitTurnCompletion(handle)
    }

    /// Suspends until the runtime stream associated with the most recent
    /// send/regenerate/edit call terminates.
    ///
    /// Retained for focused coordinator tests and legacy internal call sites.
    /// New turn-driving code should use ``awaitTurnCompletion(_:)``.
    func awaitStreamCompletion() async {
        await generationCoordinator.awaitStreamCompletion()
    }

    /// Substitutes `{{key}}` tokens in `text` with values from `context`.
    ///
    /// Single-pass scan: each `{{word}}` token in the source is examined exactly
    /// once, so substitution is non-recursive (a value containing `{{otherKey}}`
    /// is not re-expanded) and the result does not depend on dictionary
    /// iteration order. Tokens whose key is not present in `context` are left
    /// untouched, mirroring the pass-through behavior documented on
    /// ``ChatViewModel/systemPromptContext``.
    public nonisolated static func applySystemPromptContext(_ text: String, context: [String: String]) -> String {
        guard !context.isEmpty, text.contains("{{") else { return text }
        let regex = _systemPromptContextRegex
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        // Walk matches in reverse so replacement ranges remain valid as we mutate.
        let matches = regex.matches(in: text, options: [], range: fullRange).reversed()
        var result = text
        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: result),
                  let fullMatchRange = Range(match.range, in: result) else { continue }
            let key = String(result[keyRange])
            if let replacement = context[key] {
                result.replaceSubrange(fullMatchRange, with: replacement)
            }
        }
        return result
    }
}
