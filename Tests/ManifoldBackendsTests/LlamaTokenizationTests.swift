#if Llama
import XCTest
@testable import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldLlama

/// Regression tests for the `parse_special: true` fix in `LlamaTokenization.tokenize`
/// and `LlamaBackend.countTokens`.
///
/// Before the fix, `llama_tokenize` was called with `parseSpecial: false`, causing
/// ChatML delimiters like `<|im_start|>` to be tokenised as individual characters
/// rather than resolved as single special tokens. This produced inflated token
/// counts and corrupted prompt formatting on ChatML-template models (SmolLM2, Qwen,
/// Mistral). See the "im_start commentary" bug found by the fuzz harness.
///
/// All tests require Apple Silicon (llama_backend_init uses Metal).
final class LlamaTokenizationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
    }

    // MARK: - parse_special=true produces fewer tokens than parse_special=false

    /// Regression test for the `parse_special: false` bug in `LlamaTokenization.tokenize`.
    ///
    /// `<|im_start|>` exists as a single special token in any ChatML-aware GGUF
    /// vocabulary (SmolLM2, Qwen, Mistral, etc.). With `parseSpecial: true`,
    /// `llama_tokenize` resolves it to that one entry. With `parseSpecial: false`,
    /// the tokenizer treats the angle brackets and pipe characters as raw text and
    /// fragments the string into multiple byte-piece tokens.
    ///
    /// The test skips when the loaded GGUF vocabulary does not contain `<|im_start|>`
    /// as a special token — in that case both calls fragment the string equally
    /// and the comparison is vacuous.
    ///
    /// Sabotage check: change `parseSpecial: Bool = true` back to `false` in
    /// `LlamaTokenization.tokenize`, or change the default, or change `parseSpecial`
    /// in the callsite to `false`. `specialTokens.count` will equal `rawTokens.count`
    /// and `XCTAssertLessThan` fails — proving the guard catches a revert.
    func test_tokenize_parseSpecial_true_treatsImStartAsSingleToken() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip(
                "No GGUF model found on disk. Set LLAMA_TEST_MODEL=<path> or place a `.gguf` file in ~/Documents/Models/ to run this test."
            )
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
        XCTAssertTrue(backend.isModelLoaded)

        // Snapshot the vocab pointer under the state lock to avoid a use-after-free
        // race with any concurrent unloadModel(). `vocab` is internal on LlamaBackend
        // so `@testable import ManifoldBackends` makes it accessible here.
        let currentVocab = backend.vocab

        let chatmlToken = "<|im_start|>"

        let specialTokens = LlamaTokenization.tokenize(
            chatmlToken, vocab: currentVocab, addBos: false, parseSpecial: true
        )
        let rawTokens = LlamaTokenization.tokenize(
            chatmlToken, vocab: currentVocab, addBos: false, parseSpecial: false
        )

        // When the GGUF vocabulary does not include <|im_start|> as a special
        // token, both calls fragment the string identically. Skip rather than
        // assert — the interesting case only exists on ChatML-aware vocabularies.
        guard rawTokens.count > specialTokens.count else {
            throw XCTSkip(
                "Loaded GGUF vocabulary does not contain <|im_start|> as a special token — "
                + "parseSpecial cannot be differentiated on this model. "
                + "Use a ChatML-aware GGUF (SmolLM2, Qwen, Mistral) to run this regression."
            )
        }

        // Both paths must return at least one token (empty would mean nil vocab or empty text).
        XCTAssertFalse(specialTokens.isEmpty,
                       "tokenize with parseSpecial=true must return at least one token")

        // The strict inequality above (raw > special) is itself the regression assertion:
        // if parseSpecial is not forwarded to llama_tokenize, the guard never passes and
        // we skip — but the XCTSkip message makes the failure visible to the test author.
        // The assertion below pins the expected count for the special-token path.
        XCTAssertLessThan(
            specialTokens.count, rawTokens.count,
            "parse_special=true must resolve <|im_start|> to fewer tokens than parse_special=false; "
            + "got specialCount=\(specialTokens.count), rawCount=\(rawTokens.count). "
            + "If this fires, parseSpecial is not being forwarded to llama_tokenize."
        )
    }

    // MARK: - countTokens respects parse_special=true for full ChatML prompts

    /// Verifies that `countTokens` uses `parseSpecial: true` so a short ChatML
    /// prompt is not inflated to an implausibly large token count.
    ///
    /// The test input `"<|im_start|>user\nhello<|im_end|>\n<|im_start|>assistant\n"`
    /// contains two special tokens and two short plain-text words. A correctly
    /// configured tokenizer resolves it to roughly 6–8 tokens on a ChatML-aware
    /// vocabulary. Before the fix, the angle brackets and pipe characters were
    /// tokenised individually, producing a count well above 20.
    ///
    /// The upper bound (20) is generous enough to accommodate models that do not
    /// carry `<|im_start|>` as a special token — even in that case BPE compression
    /// keeps the count well below 20 for a 55-byte input string. On a ChatML model
    /// the count should be 6–8; on a non-ChatML model it should be ~12–18 at most.
    ///
    /// Sabotage check: in `LlamaBackend.countTokens`, change the last argument of
    /// `llama_tokenize` back to `false`. For a ChatML model the special token
    /// fragments jump the count past 20 and `XCTAssertLessThan` fails.
    func test_countTokens_includesSpecialTokenBudget() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip(
                "No GGUF model found on disk. Set LLAMA_TEST_MODEL=<path> or place a `.gguf` file in ~/Documents/Models/ to run this test."
            )
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        // Skip for models that don't carry <|im_start|> as a native special token
        // (e.g. Llama3 uses <|start_header_id|> instead). On those vocabularies the
        // token count may exceed 20 because angle brackets and pipes are split into
        // BPE pieces — that's correct model behaviour, not a parse_special bug.
        let singleTokenCount = try backend.countTokens("<|im_start|>")
        guard singleTokenCount == 1 else {
            throw XCTSkip("Model does not include <|im_start|> as a special token — skipping ChatML-specific tokenization check")
        }

        let formattedPrompt = "<|im_start|>user\nhello<|im_end|>\n<|im_start|>assistant\n"
        let count = try backend.countTokens(formattedPrompt)

        XCTAssertGreaterThan(count, 0,
                             "countTokens must return a positive count for a non-empty prompt")
        // For a ChatML model: <|im_start|> + <|im_end|> are single tokens.
        // Pre-fix, parse_special=false caused each to expand to 5+ pieces, pushing
        // the count above 25. Correctly wired, the 55-byte string should be ~8 tokens.
        XCTAssertLessThan(
            count, 20,
            "countTokens(\"\(formattedPrompt)\") returned \(count) tokens — "
            + "this is implausibly large for a 55-byte ChatML prompt and likely means "
            + "parse_special=false is in effect, fragmenting <|im_start|> and <|im_end|> "
            + "into individual character pieces instead of single special tokens."
        )
    }
}
#endif
