import XCTest
@testable import BaseChatInference

/// Coverage for ``BackendLoadOptions`` — the value type that carries KV cache
/// quantization, Flash Attention, and prefill batch size into the local
/// backends' load path.
final class BackendLoadOptionsTests: XCTestCase {

    // MARK: - Defaults

    func test_default_usesBackendTunedDefaults() {
        let opts = BackendLoadOptions.default
        XCTAssertEqual(opts.kvCacheQuantization, .q8,
                       "Default uses Q8 KV cache to reduce local backend memory pressure")
        XCTAssertEqual(opts.flashAttention, BackendLoadOptions.platformDefaultFlashAttention,
                       "Flash Attention defaults on for physical devices and off for simulator")
        XCTAssertNil(opts.prefillBatchSize,
                      "Default leaves prefill batch at the library default (nil sentinel)")
    }

    func test_init_propagatesAllFields() {
        let opts = BackendLoadOptions(
            kvCacheQuantization: .q8,
            flashAttention: true,
            prefillBatchSize: 1024
        )
        XCTAssertEqual(opts.kvCacheQuantization, .q8)
        XCTAssertTrue(opts.flashAttention)
        XCTAssertEqual(opts.prefillBatchSize, 1024)
    }

    // MARK: - Equality

    func test_equality_holdsAcrossIdenticalValues() {
        XCTAssertEqual(
            BackendLoadOptions(kvCacheQuantization: .q4, flashAttention: true, prefillBatchSize: 2048),
            BackendLoadOptions(kvCacheQuantization: .q4, flashAttention: true, prefillBatchSize: 2048)
        )
    }

    func test_equality_distinguishesEachField() {
        let base = BackendLoadOptions(kvCacheQuantization: .f16, flashAttention: false, prefillBatchSize: nil)
        XCTAssertNotEqual(base, BackendLoadOptions(kvCacheQuantization: .q8, flashAttention: false, prefillBatchSize: nil))
        XCTAssertNotEqual(base, BackendLoadOptions(kvCacheQuantization: .f16, flashAttention: true, prefillBatchSize: nil))
        XCTAssertNotEqual(base, BackendLoadOptions(kvCacheQuantization: .f16, flashAttention: false, prefillBatchSize: 512))
    }

    // MARK: - KVCacheQuantization enum

    func test_kvCacheQuantization_allCasesAreDistinct() {
        XCTAssertEqual(BackendLoadOptions.KVCacheQuantization.allCases.count, 3)
        XCTAssertEqual(Set(BackendLoadOptions.KVCacheQuantization.allCases),
                       [.f16, .q8, .q4])
    }

    func test_kvCacheQuantization_codableUsesRawString() throws {
        // Pinning the wire format — if these change, persisted preset payloads break.
        let cases: [BackendLoadOptions.KVCacheQuantization] = [.f16, .q8, .q4]
        let data = try JSONEncoder().encode(cases)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"f16\""))
        XCTAssertTrue(json.contains("\"q8\""))
        XCTAssertTrue(json.contains("\"q4\""))

        let decoded = try JSONDecoder().decode([BackendLoadOptions.KVCacheQuantization].self, from: data)
        XCTAssertEqual(decoded, cases)
    }

    // MARK: - Codable round-trip

    func test_codable_roundtripPreservesAllFields() throws {
        let original = BackendLoadOptions(
            kvCacheQuantization: .q8,
            flashAttention: true,
            prefillBatchSize: 1024
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BackendLoadOptions.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func test_codable_omitsPrefillBatchSizeWhenNil() throws {
        let opts = BackendLoadOptions.default  // prefillBatchSize nil
        let data = try JSONEncoder().encode(opts)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["prefillBatchSize"],
                     "nil prefillBatchSize must stay out of the wire payload to keep persisted shapes compact")
    }

    func test_codableDecode_legacyEmptyPayload_decodesToDefault() throws {
        // Forward-compat: a payload written before this type existed (or by a
        // future caller that omits all fields) must decode to the documented
        // default rather than throw.
        let legacyJSON = "{}"
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(BackendLoadOptions.self, from: data)

        XCTAssertEqual(decoded, .default)
    }

    func test_codableDecode_partialPayload_fillsMissingFieldsWithDefaults() throws {
        // Only `kvCacheQuantization` set — flashAttention and prefillBatchSize must
        // decode to current defaults so callers get a coherent value type.
        let partialJSON = """
        { "kvCacheQuantization": "q4" }
        """
        let data = try XCTUnwrap(partialJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(BackendLoadOptions.self, from: data)

        XCTAssertEqual(decoded.kvCacheQuantization, .q4)
        XCTAssertEqual(decoded.flashAttention, BackendLoadOptions.platformDefaultFlashAttention)
        XCTAssertNil(decoded.prefillBatchSize)
    }
}
