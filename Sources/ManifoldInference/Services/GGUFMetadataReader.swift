import Foundation
import os

/// Parsed metadata from a GGUF file header.
///
/// Contains the subset of GGUF metadata fields relevant to inference:
/// model name, architecture, context length, chat template, and file type (quantization).
struct GGUFMetadata: Sendable, Equatable {
    let generalName: String?
    let generalArchitecture: String?
    let contextLength: Int?
    let chatTemplate: String?
    let fileType: Int?
    let kvCacheParameters: GGUFKVCacheParameters?

    init(
        generalName: String?,
        generalArchitecture: String?,
        contextLength: Int?,
        chatTemplate: String?,
        fileType: Int?,
        kvCacheParameters: GGUFKVCacheParameters? = nil
    ) {
        self.generalName = generalName
        self.generalArchitecture = generalArchitecture
        self.contextLength = contextLength
        self.chatTemplate = chatTemplate
        self.fileType = fileType
        self.kvCacheParameters = kvCacheParameters
    }
}

/// Errors that can occur when reading GGUF metadata.
enum GGUFReaderError: LocalizedError {
    case invalidMagic
    case unsupportedVersion(Int)
    case readError(String)

    var errorDescription: String? {
        switch self {
        case .invalidMagic:
            "File is not a valid GGUF file (invalid magic bytes)"
        case .unsupportedVersion(let version):
            "Unsupported GGUF version: \(version) (expected 2 or 3)"
        case .readError(let detail):
            "Failed to read GGUF metadata: \(detail)"
        }
    }
}

/// Pure Swift binary parser that reads GGUF header metadata without loading the model.
///
/// Only reads the metadata key-value section at the start of the file. Tensor data
/// (which can be many gigabytes) is never touched. Uses `FileHandle` for sequential
/// reads to avoid loading the file into memory.
struct GGUFMetadataReader {

    /// The four-byte magic at offset 0 of every GGUF file.
    private static let magicBytes: [UInt8] = [0x47, 0x47, 0x55, 0x46] // "GGUF"

    /// GGUF metadata value type codes.
    private enum ValueType: UInt32 {
        case uint8 = 0
        case int8 = 1
        case uint16 = 2
        case int16 = 3
        case uint32 = 4
        case int32 = 5
        case float32 = 6
        case bool = 7
        case string = 8
        case array = 9
        case uint64 = 10
        case int64 = 11
        case float64 = 12
    }

    // MARK: - Public API

    /// Reads metadata from a GGUF file header.
    ///
    /// Only reads the metadata section (before tensor data). The file handle is
    /// opened, read sequentially, and closed automatically.
    ///
    /// - Parameter url: Path to a `.gguf` file on disk.
    /// - Returns: Parsed metadata fields.
    /// - Throws: `GGUFReaderError` if the file is invalid or unreadable.
    static func readMetadata(from url: URL) throws -> GGUFMetadata {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw GGUFReaderError.readError("Cannot open file: \(error.localizedDescription)")
        }
        defer { handle.closeFile() }

        return try autoreleasepool {
            // Magic bytes (4 bytes)
            guard let magicData = readBytes(from: handle, count: 4),
                  Array(magicData) == magicBytes else {
                throw GGUFReaderError.invalidMagic
            }

            // Version (uint32 LE)
            let version = try readUInt32(from: handle)
            guard version == 2 || version == 3 else {
                throw GGUFReaderError.unsupportedVersion(Int(version))
            }

            let isV3 = version == 3

            // Tensor count
            let _: UInt64 = isV3 ? try readUInt64(from: handle) : UInt64(try readUInt32(from: handle))

            // Metadata KV count
            let metadataCount: UInt64 = isV3 ? try readUInt64(from: handle) : UInt64(try readUInt32(from: handle))

            Log.inference.debug("GGUF v\(version): \(metadataCount) metadata entries")

            // Keys we want to extract
            var generalName: String?
            var generalArchitecture: String?
            var contextLength: Int?
            var chatTemplate: String?
            var fileType: Int?
            var inferredArchitecture: String?
            var blockCount: Int?
            var embeddingLength: Int?
            var attentionHeadCount: Int?
            var attentionHeadCountKV: Int?
            var attentionKeyLength: Int?
            var attentionValueLength: Int?

            // Iterate KV pairs
            for _ in 0..<metadataCount {
                let key = try readString(from: handle)
                let valueTypeRaw = try readUInt32(from: handle)

                // Check if this is a key we care about
                switch key {
                case "general.name":
                    generalName = try readStringValue(type: valueTypeRaw, from: handle)

                case "general.architecture":
                    generalArchitecture = try readStringValue(type: valueTypeRaw, from: handle)
                    if inferredArchitecture == nil {
                        inferredArchitecture = generalArchitecture
                    }

                case "general.file_type":
                    fileType = try readIntegerValue(type: valueTypeRaw, from: handle)

                case "tokenizer.chat_template":
                    chatTemplate = try readStringValue(type: valueTypeRaw, from: handle)

                default:
                    let activeArchitecture = generalArchitecture ?? inferredArchitecture

                    if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".context_length",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        contextLength = try readIntegerValue(type: valueTypeRaw, from: handle)
                    } else if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".block_count",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        blockCount = try readIntegerValue(type: valueTypeRaw, from: handle)
                    } else if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".embedding_length",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        embeddingLength = try readIntegerValue(type: valueTypeRaw, from: handle)
                    } else if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".attention.head_count",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        attentionHeadCount = try readIntegerValue(type: valueTypeRaw, from: handle)
                    } else if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".attention.head_count_kv",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        attentionHeadCountKV = try readIntegerValue(type: valueTypeRaw, from: handle)
                    } else if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".attention.key_length",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        attentionKeyLength = try readIntegerValue(type: valueTypeRaw, from: handle)
                    } else if let prefix = matchingArchitecturePrefix(
                        for: key,
                        suffix: ".attention.value_length",
                        expectedArchitecture: activeArchitecture
                    ) {
                        inferredArchitecture = inferredArchitecture ?? prefix
                        attentionValueLength = try readIntegerValue(type: valueTypeRaw, from: handle)
                    } else {
                        try skipValue(type: valueTypeRaw, from: handle)
                    }
                }
            }

            Log.inference.info(
                "GGUF metadata: name=\(generalName ?? "nil", privacy: .public), arch=\(generalArchitecture ?? "nil", privacy: .public), ctx=\(contextLength.map(String.init) ?? "nil", privacy: .public), template=\(chatTemplate != nil ? "present" : "nil", privacy: .public)"
            )

            return GGUFMetadata(
                generalName: generalName,
                generalArchitecture: generalArchitecture,
                contextLength: contextLength,
                chatTemplate: chatTemplate,
                fileType: fileType,
                kvCacheParameters: GGUFKVCacheParameters(
                    blockCount: blockCount,
                    embeddingLength: embeddingLength,
                    attentionHeadCount: attentionHeadCount,
                    attentionHeadCountKV: attentionHeadCountKV,
                    attentionKeyLength: attentionKeyLength,
                    attentionValueLength: attentionValueLength
                )
            )
        }
    }

    /// Validates that a file has valid GGUF magic bytes.
    ///
    /// - Parameter url: Path to check.
    /// - Returns: `true` if the first 4 bytes are the GGUF magic.
    static func isValidGGUF(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }

        guard let data = readBytes(from: handle, count: 4) else { return false }
        return Array(data) == magicBytes
    }

    // MARK: - Primitive Readers

    private static func readBytes(from handle: FileHandle, count: Int) -> Data? {
        let data = handle.readData(ofLength: count)
        guard data.count == count else { return nil }
        return data
    }

    private static func readUInt8(from handle: FileHandle) throws -> UInt8 {
        guard let data = readBytes(from: handle, count: 1) else {
            throw GGUFReaderError.readError("Unexpected end of file reading uint8")
        }
        return data[data.startIndex]
    }

    private static func readUInt16(from handle: FileHandle) throws -> UInt16 {
        guard let data = readBytes(from: handle, count: 2) else {
            throw GGUFReaderError.readError("Unexpected end of file reading uint16")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
    }

    private static func readUInt32(from handle: FileHandle) throws -> UInt32 {
        guard let data = readBytes(from: handle, count: 4) else {
            throw GGUFReaderError.readError("Unexpected end of file reading uint32")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    private static func readInt32(from handle: FileHandle) throws -> Int32 {
        guard let data = readBytes(from: handle, count: 4) else {
            throw GGUFReaderError.readError("Unexpected end of file reading int32")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).littleEndian }
    }

    private static func readUInt64(from handle: FileHandle) throws -> UInt64 {
        guard let data = readBytes(from: handle, count: 8) else {
            throw GGUFReaderError.readError("Unexpected end of file reading uint64")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    }

    private static func readInt64(from handle: FileHandle) throws -> Int64 {
        guard let data = readBytes(from: handle, count: 8) else {
            throw GGUFReaderError.readError("Unexpected end of file reading int64")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self).littleEndian }
    }

    private static func readFloat32(from handle: FileHandle) throws -> Float {
        guard let data = readBytes(from: handle, count: 4) else {
            throw GGUFReaderError.readError("Unexpected end of file reading float32")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }

    private static func readFloat64(from handle: FileHandle) throws -> Double {
        guard let data = readBytes(from: handle, count: 8) else {
            throw GGUFReaderError.readError("Unexpected end of file reading float64")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
    }

    /// Reads a GGUF string: uint64 length prefix followed by that many UTF-8 bytes.
    private static func readString(from handle: FileHandle) throws -> String {
        let length = try readUInt64(from: handle)
        guard length <= 1_000_000 else {
            throw GGUFReaderError.readError("String length \(length) exceeds safety limit")
        }
        guard let data = readBytes(from: handle, count: Int(length)) else {
            throw GGUFReaderError.readError("Unexpected end of file reading string of length \(length)")
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw GGUFReaderError.readError("Invalid UTF-8 in string of length \(length)")
        }
        return string
    }

    // MARK: - Typed Value Readers

    /// Reads a value expected to be a STRING, returning it. Throws if wrong type.
    private static func readStringValue(type: UInt32, from handle: FileHandle) throws -> String? {
        guard type == ValueType.string.rawValue else {
            try skipValue(type: type, from: handle)
            return nil
        }
        return try readString(from: handle)
    }

    /// Reads a scalar integer value, accepting signed or unsigned 32/64-bit GGUF integers.
    private static func readIntegerValue(type: UInt32, from handle: FileHandle) throws -> Int? {
        switch ValueType(rawValue: type) {
        case .uint32:
            return Int(try readUInt32(from: handle))
        case .int32:
            return Int(try readInt32(from: handle))
        case .uint64:
            return Int(try readUInt64(from: handle))
        case .int64:
            return Int(try readInt64(from: handle))
        default:
            try skipValue(type: type, from: handle)
            return nil
        }
    }

    private static func matchingArchitecturePrefix(
        for key: String,
        suffix: String,
        expectedArchitecture: String?
    ) -> String? {
        guard key.hasSuffix(suffix) else { return nil }
        let prefix = String(key.dropLast(suffix.count))
        // GGUF architecture names are single identifiers (llama, phi, gemma, …).
        // Reject multi-component prefixes so keys like `general.custom.context_length`
        // don't poison inferredArchitecture with "general.custom".
        guard !prefix.isEmpty, !prefix.contains(".") else { return nil }
        guard expectedArchitecture == nil || expectedArchitecture == prefix else {
            return nil
        }
        return prefix
    }

    // MARK: - Value Skipping

    /// Skips a value of the given type without parsing it.
    ///
    /// For arrays, recursively skips each element. For strings, reads the length prefix
    /// and skips that many bytes.
    private static func skipValue(type: UInt32, from handle: FileHandle) throws {
        guard let valueType = ValueType(rawValue: type) else {
            throw GGUFReaderError.readError("Unknown value type: \(type)")
        }

        switch valueType {
        case .uint8, .int8, .bool:
            _ = try readUInt8(from: handle)

        case .uint16, .int16:
            _ = try readUInt16(from: handle)

        case .uint32, .int32, .float32:
            _ = try readUInt32(from: handle)

        case .uint64, .int64, .float64:
            _ = try readUInt64(from: handle)

        case .string:
            _ = try readString(from: handle)

        case .array:
            let elementType = try readUInt32(from: handle)
            let count = try readUInt64(from: handle)
            for _ in 0..<count {
                try skipValue(type: elementType, from: handle)
            }
        }
    }
}
