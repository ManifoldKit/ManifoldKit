#if Server
import ManifoldInference
import Foundation

// MARK: - Request / response types (OpenAI-compatible)

/// Accepts either a single string or an array of strings as the `input` field,
/// matching the OpenAI embeddings API contract.
internal enum EmbedInput: Codable, Equatable, Sendable {
    case string(String)
    case strings([String])

    internal var texts: [String] {
        switch self {
        case .string(let s): [s]
        case .strings(let arr): arr
        }
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            self = .string(single)
            return
        }
        let array = try container.decode([String].self)
        self = .strings(array)
    }

    internal func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .strings(let arr): try container.encode(arr)
        }
    }
}

internal struct EmbedRequest: Codable, Equatable, Sendable {
    internal var model: String
    internal var input: EmbedInput
    internal var encodingFormat: String?
    internal var dimensions: Int?

    internal init(
        model: String,
        input: EmbedInput,
        encodingFormat: String? = nil,
        dimensions: Int? = nil
    ) {
        self.model = model
        self.input = input
        self.encodingFormat = encodingFormat
        self.dimensions = dimensions
    }

    private enum CodingKeys: String, CodingKey {
        case model, input, dimensions
        case encodingFormat = "encoding_format"
    }
}

/// The wire shape of the `embedding` field, matching the OpenAI embeddings
/// API's `encoding_format` request parameter (`float` — a JSON array of
/// numbers, the default; or `base64` — the raw little-endian float32 bytes,
/// base64-encoded, primarily to shrink response payload size for large
/// vectors).
internal enum EmbeddingEncodingFormat: String, Codable, Equatable, Sendable {
    case float
    case base64
}

internal struct EmbedObject: Codable, Equatable, Sendable {
    internal var object: String
    internal var index: Int
    internal var embedding: [Float]
    /// Wire shape for `embedding` on encode. Not itself part of the OpenAI
    /// response schema — it exists only to drive `encode(to:)`.
    internal var encodingFormat: EmbeddingEncodingFormat

    internal init(
        object: String = "embedding",
        index: Int,
        embedding: [Float],
        encodingFormat: EmbeddingEncodingFormat = .float
    ) {
        self.object = object
        self.index = index
        self.embedding = embedding
        self.encodingFormat = encodingFormat
    }

    private enum CodingKeys: String, CodingKey {
        case object, index, embedding
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try container.decode(String.self, forKey: .object)
        index = try container.decode(Int.self, forKey: .index)
        if let floats = try? container.decode([Float].self, forKey: .embedding) {
            embedding = floats
            encodingFormat = .float
        } else {
            let base64String = try container.decode(String.self, forKey: .embedding)
            embedding = try Self.floats(fromBase64: base64String, codingPath: decoder.codingPath)
            encodingFormat = .base64
        }
    }

    internal func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(object, forKey: .object)
        try container.encode(index, forKey: .index)
        switch encodingFormat {
        case .float:
            try container.encode(embedding, forKey: .embedding)
        case .base64:
            try container.encode(Self.base64String(from: embedding), forKey: .embedding)
        }
    }

    /// Packs a float vector as little-endian float32 bytes, base64-encoded —
    /// the OpenAI `encoding_format: "base64"` wire shape.
    internal static func base64String(from vector: [Float]) -> String {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }

    private static func floats(fromBase64 string: String, codingPath: [any CodingKey]) throws -> [Float] {
        guard let data = Data(base64Encoded: string), data.count % 4 == 0 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: codingPath, debugDescription: "Invalid base64 embedding payload")
            )
        }
        var floats: [Float] = []
        floats.reserveCapacity(data.count / 4)
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: 4)
            let bits = data[index..<end].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            floats.append(Float(bitPattern: UInt32(littleEndian: bits)))
            index = end
        }
        return floats
    }
}

internal struct EmbedUsage: Codable, Equatable, Sendable {
    internal var promptTokens: Int
    internal var totalTokens: Int

    internal init(promptTokens: Int) {
        self.promptTokens = promptTokens
        self.totalTokens = promptTokens
    }

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case totalTokens = "total_tokens"
    }
}

internal struct EmbedResponse: Codable, Equatable, Sendable {
    internal var object: String
    internal var data: [EmbedObject]
    internal var model: String
    internal var usage: EmbedUsage

    internal init(object: String = "list", data: [EmbedObject], model: String, usage: EmbedUsage) {
        self.object = object
        self.data = data
        self.model = model
        self.usage = usage
    }
}

// MARK: - Handler

extension ServerApp {
    /// Handles a decoded `EmbedRequest` by routing it to the configured
    /// `EmbeddingBackend`. Returns a fully-populated `EmbedResponse` with one
    /// `EmbedObject` per input text, preserving original order.
    internal func embeddingResponse(for request: EmbedRequest) async throws -> EmbedResponse {
        guard let embeddingBackend = await backendProvider.embeddingBackend(for: ServerBackendRequest(model: request.model)) else {
            // None of ManifoldServer's built-in `--backend` selections
            // (foundation/ollama/mlx/llama/cloud) vend an `EmbeddingBackend`
            // today — see `TraitAwareServerBackendProvider.embeddingBackend(for:)`
            // for why. This is not a transient/config issue that "choosing a
            // different --backend" fixes; a host app must supply its own
            // `ServerBackendProvider` overriding `embeddingBackend(for:)`
            // (e.g. with the manifold-llama companion package's
            // `LlamaEmbeddingBackend`) to make this endpoint work.
            throw ServerError.backendUnavailable("No embedding backend is available for this server. ManifoldServer's built-in backends do not currently vend an EmbeddingBackend; a host app must supply a custom ServerBackendProvider overriding embeddingBackend(for:) — for example with manifold-llama's LlamaEmbeddingBackend — to enable POST /v1/embeddings.")
        }

        let encodingFormat = try Self.resolveEncodingFormat(request.encodingFormat)

        let texts = request.input.texts
        let vectors = try await embeddingBackend.embed(texts)
        let resizedVectors = try Self.applyDimensions(request.dimensions, to: vectors)

        let data = resizedVectors.enumerated().map { index, vector in
            EmbedObject(index: index, embedding: vector, encodingFormat: encodingFormat)
        }
        // Approximate token count as total character count ÷ 4 — consistent with
        // how OpenAI approximates tokens for billing on short inputs.
        let charCount = texts.reduce(0) { $0 + $1.count }
        let estimatedTokens = max(1, charCount / 4)
        let usage = EmbedUsage(promptTokens: estimatedTokens)

        return EmbedResponse(data: data, model: request.model, usage: usage)
    }

    /// Validates the OpenAI-compatible `encoding_format` request field.
    /// `nil` (the field is absent) defaults to `.float`, matching the OpenAI
    /// API. Any value other than `"float"`/`"base64"` is a client mistake —
    /// no silent fallback.
    private static func resolveEncodingFormat(_ raw: String?) throws -> EmbeddingEncodingFormat {
        switch raw {
        case nil, "float":
            return .float
        case "base64":
            return .base64
        case .some(let other):
            throw ServerError.invalidRequest(
                message: "encoding_format must be 'float' or 'base64'; got '\(other)'.",
                param: "encoding_format",
                code: "unsupported_value"
            )
        }
    }

    /// Applies the OpenAI-compatible `dimensions` request field by truncating
    /// each vector to its first `dimensions` components and L2-renormalizing.
    ///
    /// This mirrors OpenAI's own dimensionality-reduction technique for
    /// Matryoshka-trained embedding models (truncate + renormalize yields a
    /// usable lower-dimensional embedding for models trained to support it).
    /// ManifoldKit has no capability signal for whether a given
    /// `EmbeddingBackend`'s model was trained this way, so honoring
    /// `dimensions` here is a best-effort mechanical truncation: it always
    /// changes the vector length exactly as requested (no silent
    /// no-op), but callers should confirm their model supports meaningful
    /// truncation before relying on quality. `dimensions` requesting more
    /// components than the backend's native embedding size is rejected — we
    /// cannot fabricate additional dimensions.
    private static func applyDimensions(_ dimensions: Int?, to vectors: [[Float]]) throws -> [[Float]] {
        guard let dimensions else { return vectors }
        guard dimensions > 0 else {
            throw ServerError.invalidRequest(
                message: "dimensions must be a positive integer.",
                param: "dimensions",
                code: "invalid_value"
            )
        }
        return try vectors.map { vector in
            guard dimensions <= vector.count else {
                throw ServerError.invalidRequest(
                    message: "dimensions (\(dimensions)) exceeds this backend's native embedding size (\(vector.count)).",
                    param: "dimensions",
                    code: "unsupported_value"
                )
            }
            guard dimensions < vector.count else { return vector }
            let truncated = Array(vector.prefix(dimensions))
            let norm = Foundation.sqrt(truncated.reduce(Float(0)) { $0 + $1 * $1 })
            guard norm > 0 else { return truncated }
            return truncated.map { $0 / norm }
        }
    }
}

#endif
