import XCTest
@testable import ManifoldInference
@testable import ManifoldContract  // #1719: streaming/tokenizer seams moved to Contract
// BackendInternals SPI: seam published for the companion split (#1749).
@_spi(BackendInternals) import ManifoldContract

final class TokenizationPerformanceTests: XCTestCase {

    // MARK: - 100 chars

    func testPerf_tokenCount_100chars() {
        let text = String(repeating: "a", count: 100)
        let tokenizer = HeuristicTokenizer()
        PerfBudget.assert(.milliseconds(500)) { _ = tokenizer.tokenCount(text) }
        measure {
            _ = tokenizer.tokenCount(text)
        }
    }

    // MARK: - 1_000 chars

    func testPerf_tokenCount_1000chars() {
        let text = String(repeating: "a", count: 1_000)
        let tokenizer = HeuristicTokenizer()
        PerfBudget.assert(.milliseconds(500)) { _ = tokenizer.tokenCount(text) }
        measure {
            _ = tokenizer.tokenCount(text)
        }
    }

    // MARK: - 10_000 chars

    func testPerf_tokenCount_10000chars() {
        let text = String(repeating: "a", count: 10_000)
        let tokenizer = HeuristicTokenizer()
        PerfBudget.assert(.milliseconds(500)) { _ = tokenizer.tokenCount(text) }
        measure {
            _ = tokenizer.tokenCount(text)
        }
    }

    // MARK: - 100_000 chars

    func testPerf_tokenCount_100000chars() {
        let text = String(repeating: "a", count: 100_000)
        let tokenizer = HeuristicTokenizer()
        PerfBudget.assert(.milliseconds(500)) { _ = tokenizer.tokenCount(text) }
        measure {
            _ = tokenizer.tokenCount(text)
        }
    }
}
