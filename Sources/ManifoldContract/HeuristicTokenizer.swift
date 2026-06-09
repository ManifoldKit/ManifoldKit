import Foundation

/// A ``TokenizerProvider`` that estimates token count using ~4 characters per token.
///
/// This matches the heuristic already used by ``ContextWindowManager`` and is suitable
/// as a fallback when no model-specific tokenizer is available.
package struct HeuristicTokenizer: TokenizerProvider {
    package init() {}

    package func tokenCount(_ text: String) -> Int {
        Self.tokenCount(text)
    }

    /// Stateless variant for callers that don't hold a `HeuristicTokenizer`
    /// instance (e.g. `LlamaBackend.tokenCount(_:)` fallback when no
    /// vocabulary is loaded). Keeps the `chars / 4` heuristic in one place
    /// across `ManifoldInference` and `ManifoldBackends`.
    package static func tokenCount(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}
