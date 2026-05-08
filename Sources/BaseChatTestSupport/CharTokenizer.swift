import BaseChatInference

/// Deterministic tokenizer: 1 token per character.
///
/// Useful for tests that need exact, predictable token counts
/// without depending on a real tokenizer model.
struct CharTokenizer: TokenizerProvider {
    init() {}

    func tokenCount(_ text: String) -> Int {
        max(1, text.count)
    }
}
