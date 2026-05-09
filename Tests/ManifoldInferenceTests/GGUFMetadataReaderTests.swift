import XCTest
@testable import ManifoldInference

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
