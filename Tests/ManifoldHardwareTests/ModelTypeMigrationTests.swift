import XCTest
@testable import ManifoldHardware

/// Tests for the struct-based extensible ``ModelType`` identifier introduced
/// by arch-plan 4.1 (Wave 2 B1), mirroring `BackendNameMigrationTests` for
/// the `BackendName` enum→struct precedent (#1742).
///
/// Unlike `BackendName`, `ModelType`'s raw values never changed
/// (`"gguf"`/`"mlx"`/`"foundation"` match the former enum's case names), so
/// there is no legacy-string `parse(_:)` surface here — the load-bearing
/// guarantees are raw-value stability and wire-identical Codable.
final class ModelTypeMigrationTests: XCTestCase {

    // MARK: - Canonical raw values (persisted — must never drift)

    func test_canonicalRawValues_gguf() {
        XCTAssertEqual(ModelType.gguf.rawValue, "gguf",
                       "Raw value is persisted (ModelCatalog on-disk file); it must equal the former enum case name.")
    }

    func test_canonicalRawValues_mlx() {
        XCTAssertEqual(ModelType.mlx.rawValue, "mlx")
    }

    func test_canonicalRawValues_foundation() {
        XCTAssertEqual(ModelType.foundation.rawValue, "foundation")
    }

    // MARK: - wellKnown tripwire

    /// The number of well-known ``ModelType`` constants is load-bearing for
    /// completeness. Bumping the count means every site that iterates
    /// `ModelType.wellKnown` or special-cases the built-in types (load-plan
    /// strategy selection, download validation, UI badges) needs a review —
    /// this assertion is the tripwire that forces it when a new family lands.
    func test_wellKnown_countIsThree() {
        XCTAssertEqual(ModelType.wellKnown.count, 3,
                       "ModelType ships three well-known identifiers (gguf, mlx, foundation). "
                       + "Adding one requires reviewing sites that iterate wellKnown or default: over unknown types.")
    }

    func test_wellKnown_orderMatchesOriginalEnumDeclaration() {
        XCTAssertEqual(ModelType.wellKnown, [.gguf, .mlx, .foundation])
    }

    // MARK: - Pattern matching (static-let `case` patterns via Equatable ~=)

    /// `case .gguf:`-style patterns over the struct must keep matching exactly
    /// like the former enum-case patterns (Swift's default `~=` for Equatable).
    func test_switchPatternMatching_wellKnownAndUnknown() {
        func label(_ type: ModelType) -> String {
            switch type {
            case .gguf: return "gguf"
            case .mlx: return "mlx"
            case .foundation: return "foundation"
            default: return "unknown:\(type.rawValue)"
            }
        }
        XCTAssertEqual(label(.gguf), "gguf")
        XCTAssertEqual(label(.mlx), "mlx")
        XCTAssertEqual(label(.foundation), "foundation")
        XCTAssertEqual(label(ModelType(rawValue: "future")), "unknown:future",
                       "An unrecognised type must fall into the default: arm, not match a constant.")
    }

    // MARK: - Codable wire compatibility

    /// JSON encoding must produce a bare string (single-value container), not
    /// `{"rawValue":"gguf"}`, so the ModelCatalog's persisted snapshots stay
    /// byte-identical to those written when ModelType was an enum round-tripped
    /// through the (now-removed) private `StoredModelType: String` wrapper.
    func test_jsonEncoding_producesBareSingleValueString() throws {
        let encoded = try JSONEncoder().encode(ModelType.gguf)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertEqual(json, "\"gguf\"",
                       "ModelType must encode as a bare JSON string, not a keyed object.")
    }

    func test_jsonDecoding_fromBareSingleValueString() throws {
        let json = Data("\"mlx\"".utf8)
        let decoded = try JSONDecoder().decode(ModelType.self, from: json)
        XCTAssertEqual(decoded, .mlx)
    }

    func test_jsonRoundTrip_allWellKnown() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for type in ModelType.wellKnown {
            let data = try encoder.encode(type)
            let decoded = try decoder.decode(ModelType.self, from: data)
            XCTAssertEqual(decoded, type,
                           "JSON round-trip must produce an identical ModelType for \(type).")
        }
    }

    // MARK: - Forward-compat (unrecognised types decode successfully)

    /// An unrecognised model type from a future ManifoldKit release (or a
    /// third-party local family) must decode without throwing — the
    /// struct-based design explicitly supports this, unlike the closed enum.
    func test_decoding_unrecognisedTypeSucceeds() throws {
        let json = Data("\"futureFamily\"".utf8)
        let decoded = try JSONDecoder().decode(ModelType.self, from: json)
        XCTAssertEqual(decoded.rawValue, "futureFamily",
                       "An unrecognised ModelType should decode and preserve its raw string.")
    }

    func test_init_unrecognisedType_isDistinctFromWellKnown() {
        let unknown = ModelType(rawValue: "unknownFamily")
        XCTAssertFalse(ModelType.wellKnown.contains(unknown),
                       "An unrecognised type must not accidentally equal a well-known constant.")
    }

    // MARK: - CustomStringConvertible

    /// Several call sites log `String(describing: modelType)` as a fallback
    /// label for types without a registered descriptor
    /// (`ModelLifecycleCoordinator.modelTypeLogLabel` / `backendDisplayName`).
    /// The struct's description must be the raw value — the enum's
    /// `String(describing:)` produced the case name, which equals it.
    func test_description_isRawValue() {
        XCTAssertEqual(String(describing: ModelType.gguf), "gguf")
        XCTAssertEqual(String(describing: ModelType(rawValue: "custom")), "custom")
    }

    // MARK: - Codable sabotage guard

    /// Sabotage guard: if the custom Codable were accidentally removed and
    /// synthesis restored, the encoded form would be `{"rawValue":"gguf"}`.
    /// Decoding *that* keyed representation must fail with a type error,
    /// confirming the single-value container path is active.
    ///
    /// If this test starts *passing* when it should throw, the custom Codable
    /// has been removed — restore `init(from:)` / `encode(to:)` in ModelType.swift.
    func test_jsonDecoding_keyedContainerFails() {
        let keyedJSON = Data(#"{"rawValue":"gguf"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ModelType.self, from: keyedJSON),
            "Decoding from a keyed JSON object must fail: ModelType uses a single-value container."
        )
    }
}
