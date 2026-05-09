import XCTest
@testable import BaseChatInference

/// Tests for ``BackendName`` raw-value migration from 0.18.x display strings
/// (`"Apple"`, `"Ollama"`, `"llama.cpp"`) to the 0.19+ canonical lowercase
/// identifiers (`"foundation"`, `"ollama"`, `"llama"`).
///
/// These cover both fresh decoding through `BackendName(rawValue:)` and the
/// migration helper ``BackendName/parse(_:)`` that absorbs both shapes so
/// already-installed apps don't strand on the old persisted strings.
final class BackendNameMigrationTests: XCTestCase {

    // MARK: - Canonical raw values

    func test_canonicalRawValues_foundation() {
        XCTAssertEqual(BackendName.foundation.rawValue, "foundation",
                       "0.19 canonical raw value flipped from \"Apple\" to \"foundation\".")
    }

    func test_canonicalRawValues_ollama() {
        XCTAssertEqual(BackendName.ollama.rawValue, "ollama")
    }

    func test_canonicalRawValues_claude() {
        XCTAssertEqual(BackendName.claude.rawValue, "claude")
    }

    func test_canonicalRawValues_openAI() {
        XCTAssertEqual(BackendName.openAI.rawValue, "openAI")
    }

    func test_canonicalRawValues_mlx() {
        XCTAssertEqual(BackendName.mlx.rawValue, "mlx")
    }

    func test_canonicalRawValues_llama() {
        XCTAssertEqual(BackendName.llama.rawValue, "llama",
                       "0.19 canonical raw value flipped from \"llama.cpp\" to \"llama\".")
    }

    // MARK: - parse() — canonical (0.19+) form

    func test_parse_canonicalFoundation_returnsFoundation() {
        XCTAssertEqual(BackendName.parse("foundation"), .foundation)
    }

    func test_parse_canonicalLlama_returnsLlama() {
        XCTAssertEqual(BackendName.parse("llama"), .llama)
    }

    func test_parse_canonicalAllSixCases_roundTrip() {
        for backend in BackendName.allCases {
            XCTAssertEqual(BackendName.parse(backend.rawValue), backend,
                           "parse(\"\(backend.rawValue)\") should round-trip to .\(backend)")
        }
    }

    // MARK: - parse() — legacy (0.18.x) form

    func test_parse_legacyApple_returnsFoundation() {
        XCTAssertEqual(BackendName.parse("Apple"), .foundation,
                       "Legacy 0.18 \"Apple\" must migrate to .foundation so already-installed apps don't strand.")
    }

    func test_parse_legacyOllama_returnsOllama() {
        XCTAssertEqual(BackendName.parse("Ollama"), .ollama)
    }

    func test_parse_legacyClaude_returnsClaude() {
        XCTAssertEqual(BackendName.parse("Claude"), .claude)
    }

    func test_parse_legacyOpenAI_returnsOpenAI() {
        XCTAssertEqual(BackendName.parse("OpenAI"), .openAI)
    }

    func test_parse_legacyMLX_returnsMLX() {
        XCTAssertEqual(BackendName.parse("MLX"), .mlx)
    }

    func test_parse_legacyLlamaCpp_returnsLlama() {
        XCTAssertEqual(BackendName.parse("llama.cpp"), .llama,
                       "Legacy 0.18 \"llama.cpp\" must migrate to .llama for backward-compat reads.")
    }

    // MARK: - parse() — unrecognised input

    func test_parse_nonsenseInput_returnsNil() {
        XCTAssertNil(BackendName.parse("nonsense"))
    }

    func test_parse_emptyString_returnsNil() {
        XCTAssertNil(BackendName.parse(""))
    }

    func test_parse_caseSensitive_lowercaseAppleNotFoundation() {
        // We intentionally do not lowercase-fold input — `"apple"` is not a
        // shape we ever emitted, so accepting it would broaden the
        // backward-compat surface beyond the legacy strings we actually
        // shipped. Verifying nil here keeps the contract narrow.
        XCTAssertNil(BackendName.parse("apple"),
                     "parse() must not lowercase-fold; only the exact legacy spellings migrate.")
    }

    // MARK: - allCases tripwire

    /// The number of ``BackendName`` cases is load-bearing for switch
    /// exhaustiveness. Bumping the count means every `switch` over the type
    /// elsewhere in the codebase needs a new branch — this assertion is the
    /// tripwire that forces a code review when a new backend lands.
    func test_allCases_countIsSix() {
        XCTAssertEqual(BackendName.allCases.count, 6,
                       "BackendName ships six first-class cases (foundation, ollama, claude, openAI, mlx, llama). "
                       + "Adding one means updating switch statements that branch on the type.")
    }
}
