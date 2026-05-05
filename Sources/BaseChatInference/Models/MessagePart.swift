import Foundation

/// A discrete piece of content within a chat message.
///
/// Messages can contain multiple parts to support multimodal input (images)
/// alongside plain text, model reasoning (``thinking``), and tool calling
/// (``toolCall`` / ``toolResult``). Each part is independently typed so the
/// UI can render appropriate controls (e.g., inline images, collapsible
/// reasoning blocks) and backends can map parts to their native message
/// formats.
///
/// ## Persistence compatibility
///
/// ``BaseChatSchemaV4/ChatMessage/decode(_:)`` falls back to a `.text` part
/// when JSON decoding fails. Historically this meant pre-removal rows that
/// contained ``toolCall`` / ``toolResult`` discriminators degraded gracefully
/// to text bubbles.  Those discriminators are now first-class cases again
/// (see ``BaseChatSchemaV4``), so such rows decode correctly as their actual
/// cases. The `.text` fallback remains as a safety net for genuinely
/// malformed JSON until V5.
public enum MessagePart: Hashable, Sendable {
    case text(String)
    /// Raw image bytes the *user* uploaded as input to a multimodal model.
    ///
    /// Distinct from ``generatedImage(_:)`` — this case carries inline
    /// bytes the model is asked to look at; that case carries a file URL
    /// pointing at an image the model produced.
    case image(data: Data, mimeType: String)
    /// Accumulated model reasoning. Excluded from context window (textContent returns nil).
    ///
    /// ``signature`` carries the provider-supplied opaque token that some
    /// reasoning APIs (notably Anthropic's extended thinking) require verbatim
    /// when the block is replayed in a multi-turn request. It is `nil` for
    /// providers that don't issue one or for legacy persisted rows that
    /// pre-date the field.
    case thinking(String, signature: String? = nil)
    /// A tool invocation emitted by the model during generation.
    ///
    /// Persisted so that the conversation history preserves the full
    /// tool-calling turn (model asks → host executes → model continues).
    /// Excluded from ``textContent`` and from the accessibility label.
    case toolCall(ToolCall)
    /// The outcome of executing a ``ToolCall``, fed back into the conversation.
    ///
    /// Excluded from ``textContent`` and from the accessibility label.
    case toolResult(ToolResult)
    /// An image produced by an ``ImageGenerationBackend`` and attached to
    /// a saved message.
    ///
    /// Distinct from ``image(data:mimeType:)`` — that case carries raw
    /// bytes the user submitted as multimodal *input*; this case references
    /// a file URL whose binary is the model's *output*. Excluded from
    /// ``textContent`` (the payload's prompt is metadata, not visible
    /// chat text).
    case generatedImage(ImageMessagePayload)
}

// MARK: - Codable

extension MessagePart: Codable {

    // Pin the on-disk discriminator keys. Renaming one of these raw values
    // would silently strand every persisted row, so the wire-format
    // assertions in MessagePartToolCasesTests / MessagePartThinkingTests are
    // the sentries that catch such drift.
    private enum CodingKeys: String, CodingKey {
        case text, image, thinking, toolCall, toolResult, generatedImage
    }

    private enum ImageKeys: String, CodingKey {
        case data, mimeType
    }

    /// Nested payload used for the `.thinking` discriminator.
    ///
    /// Encoded as a structured object so the optional ``signature`` (required
    /// by Anthropic for extended-thinking replay) rides alongside the text
    /// without overloading the discriminator key. Legacy persisted rows that
    /// stored `.thinking` as a bare string still decode — see
    /// ``init(from:)``.
    private struct ThinkingPayload: Codable {
        var text: String
        var signature: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = container.allKeys
        guard let key = keys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "MessagePart: empty discriminator container"
                )
            )
        }
        if keys.count > 1 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "MessagePart: multiple discriminator keys present (\(keys.map(\.rawValue).joined(separator: ",")))"
                )
            )
        }
        switch key {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .image:
            let nested = try container.nestedContainer(keyedBy: ImageKeys.self, forKey: .image)
            let data = try nested.decode(Data.self, forKey: .data)
            let mimeType = try nested.decode(String.self, forKey: .mimeType)
            self = .image(data: data, mimeType: mimeType)
        case .thinking:
            // Accept both shapes:
            //   legacy:  {"thinking": "text"}
            //   current: {"thinking": {"text": "...", "signature": "..."}}
            // Pre-#604 rows used the bare-string form. The structured object
            // is the modern wire format; we attempt it first, then fall back
            // to the bare string only on a type-mismatch error so genuine
            // corruption still surfaces through the outer decoder.
            do {
                let payload = try container.decode(ThinkingPayload.self, forKey: .thinking)
                self = .thinking(payload.text, signature: payload.signature)
            } catch DecodingError.typeMismatch {
                let raw = try container.decode(String.self, forKey: .thinking)
                self = .thinking(raw, signature: nil)
            }
        case .toolCall:
            self = .toolCall(try container.decode(ToolCall.self, forKey: .toolCall))
        case .toolResult:
            self = .toolResult(try container.decode(ToolResult.self, forKey: .toolResult))
        case .generatedImage:
            self = .generatedImage(try container.decode(ImageMessagePayload.self, forKey: .generatedImage))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            var nested = container.nestedContainer(keyedBy: ImageKeys.self, forKey: .image)
            try nested.encode(data, forKey: .data)
            try nested.encode(mimeType, forKey: .mimeType)
        case .thinking(let text, let signature):
            // Always emit the structured object form; legacy readers in
            // BaseChatSchemaV3 decode through the branch above. A nil
            // signature is omitted to keep persisted rows compact for the
            // common (non-Anthropic) case.
            try container.encode(ThinkingPayload(text: text, signature: signature), forKey: .thinking)
        case .toolCall(let call):
            try container.encode(call, forKey: .toolCall)
        case .toolResult(let result):
            try container.encode(result, forKey: .toolResult)
        case .generatedImage(let payload):
            try container.encode(payload, forKey: .generatedImage)
        }
    }
}

extension MessagePart {

    /// The plain-text content of this part, or `nil` for non-text parts.
    public var textContent: String? {
        if case .text(let t) = self { return t }
        return nil
    }

    public var thinkingContent: String? {
        if case .thinking(let t, _) = self { return t }
        return nil
    }

    /// The provider-supplied opaque signature attached to a `.thinking`
    /// block, or `nil` for non-thinking parts and for thinking parts that
    /// have no signature.
    public var thinkingSignature: String? {
        if case .thinking(_, let sig) = self { return sig }
        return nil
    }

    /// The ``ToolCall`` payload of this part, or `nil` for non-tool-call parts.
    public var toolCallContent: ToolCall? {
        if case .toolCall(let c) = self { return c }
        return nil
    }

    /// The ``ToolResult`` payload of this part, or `nil` for non-tool-result parts.
    public var toolResultContent: ToolResult? {
        if case .toolResult(let r) = self { return r }
        return nil
    }

    /// The ``ImageMessagePayload`` of a `.generatedImage` part, or `nil`
    /// for any other case.
    public var generatedImageContent: ImageMessagePayload? {
        if case .generatedImage(let p) = self { return p }
        return nil
    }
}
