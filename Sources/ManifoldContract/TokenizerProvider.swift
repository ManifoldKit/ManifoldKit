import Foundation

/// Abstraction for counting tokens in a string.
///
/// Backends can vend a model-specific tokenizer conforming to this protocol.
/// When no real tokenizer is available, ``HeuristicTokenizer`` provides a
/// character-count estimate (~4 chars per token).
public protocol TokenizerProvider: Sendable {
    /// Returns the number of tokens in the given text.
    func tokenCount(_ text: String) -> Int
}
