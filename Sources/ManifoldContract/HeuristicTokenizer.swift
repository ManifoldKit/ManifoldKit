import Foundation

/// A ``TokenizerProvider`` that estimates token count using ~4 characters per token.
///
/// This matches the heuristic already used by `ContextWindowManager` and is suitable
/// as a fallback when no model-specific tokenizer is available.
// @_spi(BackendInternals): published for the backend family packages
// (manifold-mlx / manifold-llama, #1749). `LlamaBackend` falls back to the
// chars/4 heuristic when no vocabulary is loaded; keeping the heuristic in
// one place requires a cross-package (but non-API) symbol.
@_spi(BackendInternals) public struct HeuristicTokenizer: TokenizerProvider {
    public init() {}

    public func tokenCount(_ text: String) -> Int {
        Self.tokenCount(text)
    }

    /// Stateless variant for callers that don't hold a `HeuristicTokenizer`
    /// instance (e.g. `LlamaBackend.tokenCount(_:)` fallback when no
    /// vocabulary is loaded). Keeps the `chars / 4` heuristic in one place
    /// across `ManifoldInference` and the backend families (including the
    /// manifold-mlx / manifold-llama companion packages).
    public static func tokenCount(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}
