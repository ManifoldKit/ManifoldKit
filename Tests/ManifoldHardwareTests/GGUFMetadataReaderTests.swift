import XCTest
@testable import ManifoldHardware
@_spi(BackendInternals) import ManifoldHardware

final class GGUFMetadataReaderTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GGUFReaderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    // MARK: - Valid V3 Header Tests

    func test_readMetadata_validV3Header_extractsName() throws {
        let data = makeGGUFV3Header(metadata: [
            makeStringKV(key: "general.name", value: "TestModel")
        ])
        let url = try writeTempFile(named: "test.gguf", data: data)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)

        XCTAssertEqual(metadata.generalName, "TestModel")
    }

    func test_readMetadata_validV3Header_extractsArchitecture() throws {
        let data = makeGGUFV3Header(metadata: [
            makeStringKV(key: "general.architecture", value: "llama")
        ])
        let url = try writeTempFile(named: "test.gguf", data: data)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)

        XCTAssertEqual(metadata.generalArchitecture, "llama")
    }

    func test_readMetadata_validV3Header_extractsChatTemplate() throws {
        let template = "{% if messages[0]['role'] == 'system' %}<|im_start|>system\n{{ messages[0]['content'] }}<|im_end|>\n{% endif %}"
        let data = makeGGUFV3Header(metadata: [
            makeStringKV(key: "tokenizer.chat_template", value: template)
        ])
        let url = try writeTempFile(named: "test.gguf", data: data)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)

        XCTAssertEqual(metadata.chatTemplate, template)
    }

    func test_readMetadata_validV3Header_extractsContextLength() throws {
        let data = makeGGUFV3Header(metadata: [
            makeStringKV(key: "general.architecture", value: "llama"),
            makeUInt32KV(key: "llama.context_length", value: 4096)
        ])
        let url = try writeTempFile(named: "test.gguf", data: data)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)

        XCTAssertEqual(metadata.contextLength, 4096)
    }

    func test_readMetadata_validV3Header_extractsFileType() throws {
        let data = makeGGUFV3Header(metadata: [
            makeUInt32KV(key: "general.file_type", value: 7)
        ])
        let url = try writeTempFile(named: "test.gguf", data: data)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)

        XCTAssertEqual(metadata.fileType, 7)
    }

    func test_readMetadata_validV3Header_extractsKVCacheParameters() throws {
        let data = makeGGUFV3Header(metadata: [
            makeStringKV(key: "general.architecture", value: "llama"),
            makeUInt32KV(key: "llama.block_count", value: 32),
            makeUInt32KV(key: "llama.embedding_length", value: 4096),
            makeUInt32KV(key: "llama.attention.head_count", value: 32),
            makeUInt32KV(key: "llama.attention.head_count_kv", value: 8),
            makeUInt32KV(key: "llama.attention.key_length", value: 128),
            makeUInt32KV(key: "llama.attention.value_length", value: 128)
        ])
        let url = try writeTempFile(named: "kv-params.gguf", data: data)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)

        XCTAssertEqual(
            metadata.kvCacheParameters,
            GGUFKVCacheParameters(
                blockCount: 32,
                embeddingLength: 4096,
                attentionHeadCount: 32,
                attentionHeadCountKV: 8,
                attentionKeyLength: 128,
                attentionValueLength: 128
            )
        )
    }

    func test_readMetadata_validV3Header_multipleKeys() throws {
        let data = makeGGUFV3Header(metadata: [
            makeStringKV(key: "general.name", value: "MyLlama"),
            makeStringKV(key: "general.architecture", value: "llama"),
            makeUInt32KV(key: "general.file_type", value: 15),
            makeUInt32KV(key: "llama.context_length", value: 8192),
            makeStringKV(key: "tokenizer.chat_template", value: "<|im_start|>test")
        ])
        let url = try writeTempFile(named: "test.gguf", data: data)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)

        XCTAssertEqual(metadata.generalName, "MyLlama")
        XCTAssertEqual(metadata.generalArchitecture, "llama")
        XCTAssertEqual(metadata.fileType, 15)
        XCTAssertEqual(metadata.contextLength, 8192)
        XCTAssertEqual(metadata.chatTemplate, "<|im_start|>test")
    }

    func test_readMetadata_skipsUnknownKeys() throws {
        let data = makeGGUFV3Header(metadata: [
            makeStringKV(key: "some.unknown.key", value: "ignored"),
            makeStringKV(key: "general.name", value: "Expected")
        ])
        let url = try writeTempFile(named: "test.gguf", data: data)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)

        XCTAssertEqual(metadata.generalName, "Expected")
    }

    // MARK: - V2 Header Tests

    func test_readMetadata_validV2Header_extractsName() throws {
        let data = makeGGUFV2Header(metadata: [
            makeStringKV(key: "general.name", value: "V2Model")
        ])
        let url = try writeTempFile(named: "test_v2.gguf", data: data)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)

        XCTAssertEqual(metadata.generalName, "V2Model")
    }

    // MARK: - Error Cases

    func test_readMetadata_invalidMagic_throws() throws {
        var data = Data()
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Wrong magic
        data.append(contentsOf: withUnsafeBytes(of: UInt32(3).littleEndian) { Data($0) })
        let url = try writeTempFile(named: "bad_magic.gguf", data: data)

        XCTAssertThrowsError(try GGUFMetadataReader.readMetadata(from: url)) { error in
            guard let readerError = error as? GGUFReaderError else {
                XCTFail("Expected GGUFReaderError, got \(error)")
                return
            }
            if case .invalidMagic = readerError {
                // Expected
            } else {
                XCTFail("Expected invalidMagic, got \(readerError)")
            }
        }
    }

    func test_readMetadata_unsupportedVersion_throws() throws {
        var data = Data()
        // Valid magic
        data.append(contentsOf: [0x47, 0x47, 0x55, 0x46])
        // Version 99
        data.append(contentsOf: withUnsafeBytes(of: UInt32(99).littleEndian) { Data($0) })
        let url = try writeTempFile(named: "bad_version.gguf", data: data)

        XCTAssertThrowsError(try GGUFMetadataReader.readMetadata(from: url)) { error in
            guard let readerError = error as? GGUFReaderError else {
                XCTFail("Expected GGUFReaderError, got \(error)")
                return
            }
            if case .unsupportedVersion(99) = readerError {
                // Expected
            } else {
                XCTFail("Expected unsupportedVersion(99), got \(readerError)")
            }
        }
    }

    // MARK: - isValidGGUF

    func test_isValidGGUF_validFile_returnsTrue() throws {
        let data = makeGGUFV3Header(metadata: [])
        let url = try writeTempFile(named: "valid.gguf", data: data)

        XCTAssertTrue(GGUFMetadataReader.isValidGGUF(at: url))
    }

    // MARK: - Security: malformed input bounds

    func test_readMetadata_deeplyNestedArray_throwsBeforeStackOverflow() throws {
        // A crafted GGUF with 64 levels of nested single-element arrays must be rejected
        // by the depth limit, not crash the process via stack overflow.
        let data = makeGGUFV3Header(metadata: [makeNestedArrayKV(key: "k", depth: 64)])
        let url = try writeTempFile(named: "nested.gguf", data: data)

        XCTAssertThrowsError(try GGUFMetadataReader.readMetadata(from: url)) { error in
            guard case .readError(let msg) = error as? GGUFReaderError else {
                XCTFail("Expected readError for deep nesting, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("depth"), "Error message must mention depth limit, got: \(msg)")
        }
        // Sabotage: remove the depth guard from skipValue — readMetadata succeeds instead of
        // throwing, so the XCTAssertThrowsError assertion fails.
    }

    func test_readMetadata_largeTokenizerArray_parses() throws {
        // Real-world tokenizers ship vocab arrays well above the previous 65k cap:
        // Llama 3 ships ~128k tokens, Gemma 2 ships ~256k. Regression guard for #1468.
        let vocabCount: UInt64 = 200_000
        var arrayData = Data()
        let keyBytes = Array("tokenizer.ggml.tokens".utf8)
        appendUInt64(&arrayData, UInt64(keyBytes.count))
        arrayData.append(contentsOf: keyBytes)
        appendUInt32(&arrayData, 9)               // ARRAY
        appendUInt32(&arrayData, 0)               // element type uint8
        appendUInt64(&arrayData, vocabCount)
        arrayData.append(Data(repeating: 0x00, count: Int(vocabCount)))

        let header = makeGGUFV3Header(metadata: [
            arrayData,
            makeStringKV(key: "general.architecture", value: "llama"),
            makeUInt32KV(key: "llama.context_length", value: 4096)
        ])
        let url = try writeTempFile(named: "big-vocab.gguf", data: header)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)
        XCTAssertEqual(metadata.generalArchitecture, "llama")
        XCTAssertEqual(metadata.contextLength, 4096)
    }

    func test_readMetadata_arrayExceedingElementLimit_throws() throws {
        // A crafted GGUF with a single key whose array claims 2 000 000 elements (all uint8)
        // must be rejected by the element-count limit. The cap is sized to allow real
        // tokenizer vocab arrays (Gemma 2 ships ~256 000 tokens) — see #1468.
        let data = makeGGUFV3Header(metadata: [makeHugeArrayKV(key: "k", count: 2_000_000)])
        let url = try writeTempFile(named: "huge-array.gguf", data: data)

        XCTAssertThrowsError(try GGUFMetadataReader.readMetadata(from: url)) { error in
            guard case .readError(let msg) = error as? GGUFReaderError else {
                XCTFail("Expected readError for oversized array, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("element count"), "Error message must mention element count, got: \(msg)")
        }
    }

    // MARK: - Buffered reads + array seek (#1787)

    func test_readMetadata_stringTokensArray_thenLaterKeys_parse() throws {
        // The worst case: a large STRING `tokens` array (no array-level byte count,
        // must be walked element-by-element via skipString) followed by numeric
        // companions and the keys we extract. Proves the parser lands at the right
        // offset after skipping a string array.
        let tokenCount = 5_000
        let header = makeGGUFV3Header(metadata: [
            makeStringArrayKV(key: "tokenizer.ggml.tokens", count: tokenCount, element: "tok"),
            makeFloat32ArrayKV(key: "tokenizer.ggml.scores", count: tokenCount),
            makeInt32ArrayKV(key: "tokenizer.ggml.token_type", count: tokenCount),
            makeStringKV(key: "general.name", value: "AfterArrays"),
            makeStringKV(key: "general.architecture", value: "llama"),
            makeUInt32KV(key: "llama.context_length", value: 8192)
        ])
        let url = try writeTempFile(named: "string-array.gguf", data: header)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)

        XCTAssertEqual(metadata.generalName, "AfterArrays", "Keys after a string array must parse — proves correct post-walk offset")
        XCTAssertEqual(metadata.generalArchitecture, "llama")
        XCTAssertEqual(metadata.contextLength, 8192)
    }

    func test_readMetadata_fixedWidthArray_thenLaterKeys_parse() throws {
        // A fixed-width (f32) array is skipped via a single seek of count*4 bytes.
        // The key AFTER it must still parse — proving the seek arithmetic is exact.
        //
        // Sabotage proof (verified manually, not committed live): writing a declared
        // count one element short of the bytes written lands the parser early, so
        // `general.name` no longer equals "SeekTarget" and the assertion below fails.
        let count = 50_000
        let header = makeGGUFV3Header(metadata: [
            makeFloat32ArrayKV(key: "tokenizer.ggml.scores", count: count),
            makeStringKV(key: "general.name", value: "SeekTarget"),
            makeStringKV(key: "general.architecture", value: "llama"),
            makeUInt32KV(key: "llama.context_length", value: 4096)
        ])
        let url = try writeTempFile(named: "fixedwidth-array.gguf", data: header)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)
        XCTAssertEqual(metadata.generalName, "SeekTarget")
        XCTAssertEqual(metadata.contextLength, 4096)
    }

    func test_readMetadata_primitiveStraddlingChunkBoundary_parses() throws {
        // Force a value to be read across the 64 KiB buffer refill: pad the metadata
        // region with a filler string larger than one chunk so the keys after it are
        // served from a later refill, and a multi-byte primitive spans the boundary.
        //
        // Sabotage proof (verified manually): if BufferedFileReader.read returned only
        // the first-chunk bytes instead of reassembling across refills, contextLength
        // would be garbage and the assertion fails.
        let chunk = 64 * 1024

        var meta: [Data] = []
        let fillerValue = String(repeating: "x", count: chunk + 7)  // > one chunk, odd tail
        meta.append(makeStringKV(key: "filler", value: fillerValue))
        meta.append(makeStringKV(key: "general.architecture", value: "llama"))
        meta.append(makeUInt32KV(key: "llama.context_length", value: 123_456))
        meta.append(makeStringKV(key: "general.name", value: "BoundaryModel"))

        let header = makeGGUFV3Header(metadata: meta)
        let url = try writeTempFile(named: "boundary.gguf", data: header)

        let metadata = try GGUFMetadataReader.readMetadata(from: url)
        XCTAssertEqual(metadata.contextLength, 123_456, "uint32 read across a buffer refill must reassemble correctly")
        XCTAssertEqual(metadata.generalName, "BoundaryModel")
        XCTAssertEqual(metadata.generalArchitecture, "llama")
    }

    func test_readMetadata_goldenParity_v2_and_v3() throws {
        // Golden-parity: a representative metadata set (including a string array +
        // numeric companion) must produce byte-identical parsed fields across v2 and
        // v3 envelopes, and match the captured baseline.
        let kvs: [Data] = [
            makeStringArrayKV(key: "tokenizer.ggml.tokens", count: 1_000, element: "t"),
            makeFloat32ArrayKV(key: "tokenizer.ggml.scores", count: 1_000),
            makeStringKV(key: "general.name", value: "GoldenModel"),
            makeStringKV(key: "general.architecture", value: "gemma"),
            makeUInt32KV(key: "general.file_type", value: 15),
            makeUInt32KV(key: "gemma.context_length", value: 8192),
            makeUInt32KV(key: "gemma.block_count", value: 28),
            makeUInt32KV(key: "gemma.embedding_length", value: 3072),
            makeUInt32KV(key: "gemma.attention.head_count", value: 16),
            makeUInt32KV(key: "gemma.attention.head_count_kv", value: 8),
            makeStringKV(key: "tokenizer.chat_template", value: "<|im_start|>{{x}}")
        ]
        let v3 = try writeTempFile(named: "golden-v3.gguf", data: makeGGUFV3Header(metadata: kvs))
        let v2 = try writeTempFile(named: "golden-v2.gguf", data: makeGGUFV2Header(metadata: kvs))

        let m3 = try GGUFMetadataReader.readMetadata(from: v3)
        let m2 = try GGUFMetadataReader.readMetadata(from: v2)

        // Baseline captured from the same metadata definition.
        let baseline = GGUFMetadata(
            generalName: "GoldenModel",
            generalArchitecture: "gemma",
            contextLength: 8192,
            chatTemplate: "<|im_start|>{{x}}",
            fileType: 15,
            kvCacheParameters: GGUFKVCacheParameters(
                blockCount: 28,
                embeddingLength: 3072,
                attentionHeadCount: 16,
                attentionHeadCountKV: 8,
                attentionKeyLength: nil,
                attentionValueLength: nil
            )
        )

        XCTAssertEqual(m3, baseline, "v3 parse must match the captured baseline")
        XCTAssertEqual(m2, baseline, "v2 parse must match the captured baseline")
        XCTAssertEqual(m2, m3, "v2 and v3 envelopes of the same metadata must parse identically")
    }

    func test_isValidGGUF_invalidFile_returnsFalse() throws {
        let data = Data(repeating: 0, count: 64)
        let url = try writeTempFile(named: "invalid.gguf", data: data)

        XCTAssertFalse(GGUFMetadataReader.isValidGGUF(at: url))
    }

    func test_isValidGGUF_missingFile_returnsFalse() {
        let url = tempDirectory.appendingPathComponent("nonexistent.gguf")

        XCTAssertFalse(GGUFMetadataReader.isValidGGUF(at: url))
    }

    // MARK: - Helpers

    /// Creates a minimal GGUF v3 header with the given metadata KV pairs.
    private func makeGGUFV3Header(metadata: [Data]) -> Data {
        var data = Data()
        // Magic: GGUF
        data.append(contentsOf: [0x47, 0x47, 0x55, 0x46])
        // Version: 3
        appendUInt32(&data, 3)
        // Tensor count: 0 (uint64 for v3)
        appendUInt64(&data, 0)
        // Metadata KV count (uint64 for v3)
        appendUInt64(&data, UInt64(metadata.count))
        // KV pairs
        for kv in metadata {
            data.append(kv)
        }
        return data
    }

    /// Creates a minimal GGUF v2 header with the given metadata KV pairs.
    private func makeGGUFV2Header(metadata: [Data]) -> Data {
        var data = Data()
        // Magic: GGUF
        data.append(contentsOf: [0x47, 0x47, 0x55, 0x46])
        // Version: 2
        appendUInt32(&data, 2)
        // Tensor count: 0 (uint32 for v2)
        appendUInt32(&data, 0)
        // Metadata KV count (uint32 for v2)
        appendUInt32(&data, UInt32(metadata.count))
        // KV pairs
        for kv in metadata {
            data.append(kv)
        }
        return data
    }

    /// Creates a STRING-typed key-value pair in GGUF format.
    private func makeStringKV(key: String, value: String) -> Data {
        var data = Data()
        // Key: uint64 length + UTF-8 bytes
        let keyBytes = Array(key.utf8)
        appendUInt64(&data, UInt64(keyBytes.count))
        data.append(contentsOf: keyBytes)
        // Value type: STRING = 8
        appendUInt32(&data, 8)
        // Value: uint64 length + UTF-8 bytes
        let valueBytes = Array(value.utf8)
        appendUInt64(&data, UInt64(valueBytes.count))
        data.append(contentsOf: valueBytes)
        return data
    }

    /// Creates a UINT32-typed key-value pair in GGUF format.
    private func makeUInt32KV(key: String, value: UInt32) -> Data {
        var data = Data()
        // Key: uint64 length + UTF-8 bytes
        let keyBytes = Array(key.utf8)
        appendUInt64(&data, UInt64(keyBytes.count))
        data.append(contentsOf: keyBytes)
        // Value type: UINT32 = 4
        appendUInt32(&data, 4)
        // Value
        appendUInt32(&data, value)
        return data
    }

    /// Builds a KV pair whose value is `depth` levels of nested single-element arrays
    /// terminating in a uint8. Used to exercise the recursion depth limit in `skipValue`.
    private func makeNestedArrayKV(key: String, depth: Int) -> Data {
        var data = Data()
        let keyBytes = Array(key.utf8)
        appendUInt64(&data, UInt64(keyBytes.count))
        data.append(contentsOf: keyBytes)
        // Value type: ARRAY = 9
        appendUInt32(&data, 9)
        // Build nested arrays: each level wraps one element of type ARRAY (9), except
        // the innermost which contains one uint8 (type 0).
        for level in 0..<depth {
            let innerType: UInt32 = level == depth - 1 ? 0 : 9  // innermost = uint8
            appendUInt32(&data, innerType)   // element type
            appendUInt64(&data, 1)           // count = 1
        }
        appendUInt8(&data, 0)               // the single innermost uint8 value
        return data
    }

    /// Builds a KV pair whose value is a uint8 array declaring `count` elements but
    /// providing no actual data. Used to exercise the element-count safety limit.
    private func makeHugeArrayKV(key: String, count: UInt64) -> Data {
        var data = Data()
        let keyBytes = Array(key.utf8)
        appendUInt64(&data, UInt64(keyBytes.count))
        data.append(contentsOf: keyBytes)
        // Value type: ARRAY = 9
        appendUInt32(&data, 9)
        appendUInt32(&data, 0)              // element type: uint8
        appendUInt64(&data, count)          // declared count (no actual bytes follow)
        return data
    }

    /// Builds a KV pair whose value is a STRING array of `count` identical-prefixed
    /// elements (`<element>-<i>`). String arrays carry NO array-level byte count, so
    /// this exercises the per-element `skipString` walk.
    private func makeStringArrayKV(key: String, count: Int, element: String) -> Data {
        var data = Data()
        let keyBytes = Array(key.utf8)
        appendUInt64(&data, UInt64(keyBytes.count))
        data.append(contentsOf: keyBytes)
        appendUInt32(&data, 9)   // ARRAY
        appendUInt32(&data, 8)   // element type: STRING
        appendUInt64(&data, UInt64(count))
        for i in 0..<count {
            let elementBytes = Array("\(element)-\(i)".utf8)
            appendUInt64(&data, UInt64(elementBytes.count))
            data.append(contentsOf: elementBytes)
        }
        return data
    }

    /// Builds a KV pair whose value is a FLOAT32 array of `count` zeroed elements.
    /// Fixed-width (4 bytes) — exercises the single-seek fast path.
    private func makeFloat32ArrayKV(key: String, count: Int) -> Data {
        var data = Data()
        let keyBytes = Array(key.utf8)
        appendUInt64(&data, UInt64(keyBytes.count))
        data.append(contentsOf: keyBytes)
        appendUInt32(&data, 9)   // ARRAY
        appendUInt32(&data, 6)   // element type: FLOAT32
        appendUInt64(&data, UInt64(count))
        data.append(Data(repeating: 0x00, count: count * 4))
        return data
    }

    /// Builds a KV pair whose value is an INT32 array of `count` zeroed elements.
    /// Fixed-width (4 bytes) — exercises the single-seek fast path.
    private func makeInt32ArrayKV(key: String, count: Int) -> Data {
        var data = Data()
        let keyBytes = Array(key.utf8)
        appendUInt64(&data, UInt64(keyBytes.count))
        data.append(contentsOf: keyBytes)
        appendUInt32(&data, 9)   // ARRAY
        appendUInt32(&data, 5)   // element type: INT32
        appendUInt64(&data, UInt64(count))
        data.append(Data(repeating: 0x00, count: count * 4))
        return data
    }

    private func appendUInt8(_ data: inout Data, _ value: UInt8) {
        data.append(value)
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt64(_ data: inout Data, _ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func writeTempFile(named name: String, data: Data) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
