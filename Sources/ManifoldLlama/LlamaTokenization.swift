#if Llama
import Foundation
import LlamaSwift

/// Pure vocabulary-backed tokenization helpers.
///
/// `llama_tokenize` and `llama_token_to_piece` are pure vocabulary lookups
/// — they do not touch context KV state, so they're safe to call from any
/// thread while the vocab pointer is live. These helpers take `vocab` as an
/// explicit parameter so callers remain responsible for guarding the pointer's
/// lifetime against a concurrent `unloadModel()`.
enum LlamaTokenization {

    static func tokenize(
        _ text: String,
        vocab: OpaquePointer?,
        addBos: Bool,
        parseSpecial: Bool = true
    ) -> [llama_token] {
        guard let vocab else { return [] }
        let utf8 = text.utf8CString
        let maxTokens = Int32(utf8.count) + (addBos ? 1 : 0)
        var tokens = [llama_token](repeating: 0, count: Int(maxTokens))
        let count = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, maxTokens, addBos, parseSpecial)
        guard count >= 0 else { return [] }
        return Array(tokens.prefix(Int(count)))
    }

    /// Converts a token to a string, handling multi-byte UTF-8 sequences that
    /// may span token boundaries.
    static func tokenToString(_ token: llama_token, vocab: OpaquePointer?, invalidUTF8Buffer: inout [CChar]) -> String? {
        guard let vocab else { return nil }
        var buf = [CChar](repeating: 0, count: 32)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)

        if n < 0 {
            // Buffer too small — retry with correct size
            buf = [CChar](repeating: 0, count: Int(-n))
            let n2 = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            guard n2 >= 0 else { return nil }
            invalidUTF8Buffer.append(contentsOf: buf.prefix(Int(n2)))
        } else {
            invalidUTF8Buffer.append(contentsOf: buf.prefix(Int(n)))
        }

        // Try to form a valid UTF-8 string
        invalidUTF8Buffer.append(0) // null-terminate
        if let str = String(validatingUTF8: invalidUTF8Buffer) {
            invalidUTF8Buffer.removeAll()
            return str.isEmpty ? nil : str
        }
        invalidUTF8Buffer.removeLast() // remove null terminator, keep accumulating
        return nil
    }
}
#endif
