import Testing
@testable import ManifoldInference
// BackendInternals SPI: seam published for the companion split (#1749).
@_spi(BackendInternals) import ManifoldContract

@Suite("HeuristicTokenizer")
struct HeuristicTokenizerTests {

    let tokenizer = HeuristicTokenizer()

    @Test func test_tokenCount_emptyString_returnsOne() {
        #expect(tokenizer.tokenCount("") == 1)
    }

    @Test func test_tokenCount_singleChar_returnsOne() {
        #expect(tokenizer.tokenCount("a") == 1)
    }

    @Test func test_tokenCount_fourChars_returnsOne() {
        #expect(tokenizer.tokenCount("abcd") == 1)
    }

    @Test func test_tokenCount_fiveChars_returnsOne() {
        #expect(tokenizer.tokenCount("abcde") == 1)
    }

    @Test func test_tokenCount_eightChars_returnsTwo() {
        #expect(tokenizer.tokenCount("abcdefgh") == 2)
    }

    @Test func test_tokenCount_hundredChars_returns25() {
        let text = String(repeating: "a", count: 100)
        #expect(tokenizer.tokenCount(text) == 25)
    }

    @Test func test_tokenCount_thousandChars_returns250() {
        let text = String(repeating: "x", count: 1000)
        #expect(tokenizer.tokenCount(text) == 250)
    }

    @Test func test_conformsToTokenizerProvider() {
        let provider: any TokenizerProvider = HeuristicTokenizer()
        #expect(provider.tokenCount("abcdefgh") == 2)
    }
}
