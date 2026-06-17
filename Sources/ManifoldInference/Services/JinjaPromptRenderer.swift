import Foundation
import Jinja

/// Renders a model's *actual* embedded GGUF Jinja chat template via `swift-jinja`.
///
/// GGUF models loaded by the local backends do not apply their own chat
/// templates — the caller must wrap messages in the format the model was
/// trained on. Historically ManifoldKit approximated this with the hand-rolled
/// ``PromptTemplate`` enum: detection picks the nearest case, then a bespoke
/// `format*` function emits a *best-effort* version of that family's layout.
///
/// That approximation is a silent-correctness gap. Many in-use models ship
/// bespoke Jinja that the enum cannot reproduce — e.g. Qwen2.5 injects a
/// mandatory default system turn ("You are Qwen, created by Alibaba Cloud…")
/// and Llama-3.2 emits a "Cutting Knowledge Date / Today Date" preamble. The
/// enum drops both, so the model receives a structurally different prompt than
/// it was trained on, producing degraded output with no error (#1811).
///
/// This renderer closes that gap: when a GGUF carries a usable Jinja chat
/// template, render the *real* template. The enum remains the fallback for
/// templateless models and for templates `swift-jinja` cannot evaluate.
enum JinjaPromptRenderer {

    /// Roles that map onto a chat-template `messages` array. Anything else is
    /// dropped before rendering — the enum path makes the same choice.
    private static let renderableRoles: Set<String> = ["system", "user", "assistant", "tool"]

    /// Renders `messages` against a raw Jinja chat-template string.
    ///
    /// - Parameters:
    ///   - rawTemplate: the model's embedded `tokenizer.chat_template` Jinja
    ///     string (from ``ModelInfo/chatTemplateRaw``).
    ///   - messages: ordered `(role, content)` pairs already flattened from the
    ///     structured history.
    ///   - systemPrompt: an optional system instruction. Prepended as a leading
    ///     `system` message when the history does not already start with one —
    ///     this matches what every chat template expects (a system turn at index
    ///     0) and lets the template's own "inject default system prompt" branch
    ///     fire only when the host supplied none.
    /// - Returns: the rendered prompt, or `nil` when the template cannot be
    ///   parsed or evaluated. A `nil` return is the signal for the caller to
    ///   fall back to the ``PromptTemplate`` enum — never a hard failure, since
    ///   a malformed embedded template must not block generation.
    static func render(
        rawTemplate: String,
        messages: [(role: String, content: String)],
        systemPrompt: String?
    ) -> String? {
        let trimmed = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var jinjaMessages: [[String: Any]] = []

        // Only synthesize a leading system message when the host supplied one and
        // the history does not already open with a system turn. If the host gave
        // no system prompt, we deliberately omit it so the template's own
        // default-system branch (Qwen2.5 et al.) can fire.
        let historyHasLeadingSystem = messages.first?.role == "system"
        if let systemPrompt, !systemPrompt.isEmpty, !historyHasLeadingSystem {
            jinjaMessages.append(["role": "system", "content": systemPrompt])
        }

        for message in messages where renderableRoles.contains(message.role) {
            jinjaMessages.append(["role": message.role, "content": message.content])
        }

        do {
            let template = try Template(trimmed)
            let context: [String: Value] = [
                "messages": try Value(any: jinjaMessages),
                "add_generation_prompt": true,
                // Many templates branch on tools/documents being defined; pass
                // empty so `{%- if tools %}` evaluates falsey rather than raising
                // an "undefined" error in stricter templates.
                "tools": try Value(any: [Any]()),
            ]
            let rendered = try template.render(context)
            // A template that evaluates to empty output is not usable — treat it
            // as a miss so the enum fallback produces a real prompt.
            return rendered.isEmpty ? nil : rendered
        } catch {
            // Do not crash generation on a malformed or unsupported embedded
            // template — log and let the caller fall back to the enum. This is a
            // recoverable boundary condition, not a programmer error.
            Log.inference.warning(
                "JinjaPromptRenderer: failed to render embedded chat template, falling back to enum: \(error.localizedDescription)"
            )
            return nil
        }
    }
}
