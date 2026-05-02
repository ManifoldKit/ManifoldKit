import Foundation

/// Classifier for OpenAI Chat Completions models that accept image inputs.
///
/// OpenAI does not expose a runtime capability probe — vision support is a
/// per-model property documented on api.openai.com. Rather than blindly
/// sending `image_url` parts and letting the request 400, we screen the
/// configured model name against a curated allowlist before encoding so the
/// caller sees a clear, actionable error.
///
/// Match semantics: case-insensitive prefix match against the configured
/// model name. The allowlist tracks the families that ship with native
/// vision support today (gpt-4o, gpt-4o-mini, gpt-4-turbo, gpt-4.1, the
/// o1 reasoning family). Any compat-server model whose name starts with
/// one of those prefixes inherits the same classification — that's
/// deliberate: third-party providers that mirror the OpenAI vision wire
/// format (LM Studio, OpenRouter, etc.) typically reuse the same model
/// identifiers.
///
/// The list is intentionally a small allowlist of public family prefixes,
/// not a full version-by-version catalogue. New OpenAI vision releases that
/// don't share an existing prefix can be added here in a one-line patch.
enum OpenAIVisionModels {

    /// Family prefixes that accept image inputs on the Chat Completions
    /// `image_url` content-part wire format.
    ///
    /// Order is irrelevant — the matcher walks the whole list. All entries
    /// are lowercase; match is case-insensitive.
    static let visionCapablePrefixes: [String] = [
        "gpt-4o",       // gpt-4o, gpt-4o-mini, gpt-4o-2024-*, etc.
        "gpt-4-turbo",  // gpt-4-turbo, gpt-4-turbo-2024-*
        "gpt-4.1",      // gpt-4.1, gpt-4.1-mini, gpt-4.1-nano
        "o1",           // o1, o1-mini, o1-pro (vision in stable & preview tiers)
        "o3",           // o3, o3-mini (reasoning + vision)
        "chatgpt-4o",   // chatgpt-4o-latest
    ]

    /// Returns `true` when `modelName` matches a known vision-capable family.
    ///
    /// An empty / whitespace-only model name returns `false` so a caller that
    /// forgets to ``CloudBackendURLModelConfigurable/configure`` doesn't
    /// silently appear vision-capable.
    static func isVisionCapable(_ modelName: String) -> Bool {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        return visionCapablePrefixes.contains { trimmed.hasPrefix($0) }
    }
}
