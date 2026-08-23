import XCTest
@testable import ManifoldInference

/// Tests for ``BackendName`` raw-value migration from 0.18.x display strings
/// (`"Apple"`, `"Ollama"`, `"llama.cpp"`) to the 0.19+ canonical lowercase
/// identifiers (`"foundation"`, `"ollama"`, `"llama"`), and for the
/// struct-based extensible identifier introduced in v1.0.
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

    func test_advancedDemoUsesCanonicalFoundationIdentity() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let demoURL = repositoryRoot.appendingPathComponent("Example/Advanced/DemoContentView.swift")
        let source = try String(contentsOf: demoURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("activeBackendName == BackendName.foundation.rawValue"),
            "The runnable demo must compare backend identity through BackendName.foundation."
        )
        XCTAssertFalse(
            source.contains("activeBackendName == \"Apple\""),
            "The legacy display value does not match the canonical active backend identity."
        )
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
                           "parse(\"\(backend.rawValue)\") should round-trip to \(backend)")
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

    // MARK: - wellKnown / allCases tripwire

    /// The number of well-known ``BackendName`` constants is load-bearing for
    /// completeness. Bumping the count means every site that iterates
    /// `BackendName.wellKnown` (or the `allCases` alias) needs a code review
    /// — this assertion is the tripwire that forces that review when a new
    /// backend lands.
    ///
    /// Note: with the struct-based open identifier, switch statements over
    /// `BackendName` values no longer need to be exhaustive — they should
    /// carry a `default:` arm for unrecognised values.
    func test_wellKnown_countIsSix() {
        XCTAssertEqual(BackendName.wellKnown.count, 6,
                       "BackendName ships six well-known identifiers (foundation, ollama, claude, openAI, mlx, llama). "
                       + "Adding one requires updating sites that iterate wellKnown/allCases.")
    }

    /// allCases is a source-compat alias for wellKnown — both must return identical ordered lists.
    func test_allCases_aliasMatchesWellKnown() {
        XCTAssertEqual(BackendName.allCases, BackendName.wellKnown,
                       "allCases must be identical to wellKnown (it is just a source-compat alias).")
    }

    // MARK: - Codable wire compatibility

    /// JSON encoding must produce a bare string (single-value container), not
    /// `{"rawValue":"foundation"}`, so persisted and wire payloads are
    /// byte-identical to those produced by the former `enum BackendName: String`.
    func test_jsonEncoding_producesBareSingleValueString() throws {
        let encoded = try JSONEncoder().encode(BackendName.foundation)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertEqual(json, "\"foundation\"",
                       "BackendName must encode as a bare JSON string, not a keyed object.")
    }

    func test_jsonDecoding_fromBareSingleValueString() throws {
        let json = Data("\"ollama\"".utf8)
        let decoded = try JSONDecoder().decode(BackendName.self, from: json)
        XCTAssertEqual(decoded, .ollama)
    }

    func test_jsonRoundTrip_allWellKnown() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for name in BackendName.wellKnown {
            let data = try encoder.encode(name)
            let decoded = try decoder.decode(BackendName.self, from: data)
            XCTAssertEqual(decoded, name,
                           "JSON round-trip must produce an identical BackendName for \(name).")
        }
    }

    // MARK: - Forward-compat (unrecognised names decode successfully)

    /// An unrecognised backend name from a future ManifoldKit release must
    /// decode without throwing — the struct-based design explicitly supports
    /// this forward-compat case, unlike the closed enum.
    func test_decoding_unrecognisedNameSucceeds() throws {
        let json = Data("\"futureBackend\"".utf8)
        let decoded = try JSONDecoder().decode(BackendName.self, from: json)
        XCTAssertEqual(decoded.rawValue, "futureBackend",
                       "An unrecognised BackendName should decode and preserve its raw string.")
    }

    func test_init_unrecognisedName_isDistinctFromWellKnown() {
        let unknown = BackendName(rawValue: "unknownBackend")
        XCTAssertFalse(BackendName.wellKnown.contains(unknown),
                       "An unrecognised name must not accidentally equal a well-known constant.")
    }

    /// Sabotage guard: if the custom Codable were accidentally removed and synthesis
    /// restored, the encoded form would be `{"rawValue":"foundation"}`. Decoding
    /// *that* keyed representation into `BackendName` must fail with a type error,
    /// confirming the single-value container path is active.
    ///
    /// If this test starts *passing* when it should throw, the custom Codable has
    /// been removed — restore `init(from:)` / `encode(to:)` in BackendName.swift.
    func test_jsonDecoding_keyedContainerFails() {
        let keyedJSON = Data(#"{"rawValue":"foundation"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(BackendName.self, from: keyedJSON),
            "Decoding from a keyed JSON object must fail: BackendName uses a single-value container."
        )
    }
}
