import Foundation
import BaseChatRuntime
import BaseChatInference

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

    /// Suspends until the runtime stream associated with the most recent
    /// send/regenerate/edit call terminates.
    ///
    /// `sendMessage()` / `regenerate()` / `edit()` use this so callers that
    /// `await` them observe the same end-of-turn state the legacy in-process
    /// orchestrator delivered.
    ///
    /// The runtime's `streamFinished` event flips ``isGenerating`` to `false`
    /// AND clears ``activeConversationStreamHandle`` via the drain task. We
    /// suspend on `activeConversationStreamHandle == nil` rather than on
    /// `isGenerating` because the drain task may not have processed
    /// `streamStarted` (which flips `isGenerating` to `true`) by the time
    /// this helper runs — a stale-`isGenerating == false` snapshot would
    /// otherwise let the helper return before any tokens stream in.
    func awaitStreamCompletion() async {
        // Yield once so any synchronously-emitted events from the runtime's
        // `send` / `regenerate` / `edit` setup phase can be drained before we
        // start polling. Without this, `messageInserted(user)` lands but the
        // detached generation `Task` has not yet emitted `streamStarted`, and
        // the early-exit below would let `sendMessage()` return before the
        // turn even begins.
        await Task.yield()
        // The stream task on the runtime side is detached, so events arrive
        // on MainActor as the drain task picks them up. A tight `Task.yield`
        // loop lets the drain pump until the handle clears, without an
        // arbitrary timeout (mock-backed unit tests finish in milliseconds;
        // production-style streams take seconds — both terminate via the
        // same handle-cleared signal).
        var ticks = 0
        while activeConversationStreamHandle != nil {
            await Task.yield()
            ticks += 1
            // Sleep on a backoff rather than busy-spinning when the
            // generation actually takes time (e.g. a slow mock). 1 ms after
            // the first 8 yields is small enough to round-trip mock tokens
            // and large enough to keep CPU off the floor on long runs.
            if ticks > 8 {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
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
