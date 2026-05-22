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

internal struct EmbedObject: Codable, Equatable, Sendable {
    internal var object: String
    internal var index: Int
    internal var embedding: [Float]

    internal init(object: String = "embedding", index: Int, embedding: [Float]) {
        self.object = object
        self.index = index
        self.embedding = embedding
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
            throw ServerError.backendUnavailable("No embedding backend is available for this server. Configure a backend that supports embedding (e.g. Llama with a text-embedding model).")
        }

        let texts = request.input.texts
        let vectors = try await embeddingBackend.embed(texts)

        let data = vectors.enumerated().map { index, vector in
            EmbedObject(index: index, embedding: vector)
        }
        // Approximate token count as total character count ÷ 4 — consistent with
        // how OpenAI approximates tokens for billing on short inputs.
        let charCount = texts.reduce(0) { $0 + $1.count }
        let estimatedTokens = max(1, charCount / 4)
        let usage = EmbedUsage(promptTokens: estimatedTokens)

        return EmbedResponse(data: data, model: request.model, usage: usage)
    }
}

#endif
