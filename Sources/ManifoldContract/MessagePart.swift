import Foundation

/// A discrete piece of content within a chat message.
///
/// Messages can contain multiple parts to support multimodal input (images
/// and audio) alongside plain text, model reasoning (``thinking(_:signature:)``), and tool
/// calling (``toolCall(_:)`` / ``toolResult(_:)``). Each part is independently typed
/// so the UI can render appropriate controls (e.g., inline images, playable
/// audio, collapsible reasoning blocks) and backends can map parts to their
/// native message formats.
///
/// ## Persistence compatibility
///
/// `ManifoldSchemaV4.ChatMessage.decode(_:)` falls back to a `.text` part
/// when JSON decoding fails. Historically this meant pre-removal rows that
/// contained ``toolCall(_:)`` / ``toolResult(_:)`` discriminators degraded gracefully
/// to text bubbles.  Those discriminators are now first-class cases again
/// (see `ManifoldSchemaV4`), so such rows decode correctly as their actual
/// cases. The `.text` fallback remains as a safety net for genuinely
/// malformed JSON until V5.
public enum MessagePart: Hashable, Sendable {
    case text(String)
    /// Raw image bytes the *user* uploaded as input to a multimodal model.
    ///
    /// Distinct from ``generatedImage(_:)`` — this case carries inline
    /// bytes the model is asked to look at; that case carries a file URL
    /// pointing at an image the model produced. The `placeholderHash` is optional
    /// so legacy persisted images and callers that do not need placeholder
    /// rendering can continue to omit it.
    case image(data: Data, mimeType: String, placeholderHash: ImagePlaceholderHash? = nil)
    /// A sandbox-local audio file rendered as an inline player.
    ///
    /// The `url` should point at a file inside the host app's container.
    /// The `waveform` stores precomputed normalized amplitude buckets so chat
    /// history can render without re-reading the audio file.
    case audio(url: URL, duration: TimeInterval, waveform: [Float]?)
    /// Accumulated model reasoning. Excluded from context window (textContent returns nil).
    ///
    /// The `signature` carries the provider-supplied opaque token that some
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
    /// A media artifact (image, video, or one-shot audio) produced by a
    /// generation backend and attached to a saved message.
    ///
    /// Distinct from ``image(data:mimeType:placeholderHash:)`` — that case
    /// carries raw bytes the user submitted as multimodal *input*; this case
    /// references a file URL whose binary is the model's *output*. Excluded
    /// from ``textContent`` (the payload's prompt is metadata, not visible chat
    /// text).
    ///
    /// Collapses the former `generatedImage` / `generatedVideo` cases into a
    /// single generic ``GeneratedMediaPayload`` carrying a ``MediaKind``
    /// discriminator (P4b). Legacy `generatedImage` / `generatedVideo` JSON
    /// rows still decode — see ``init(from:)``.
    case generatedMedia(GeneratedMediaPayload)
}

// MARK: - Codable

extension MessagePart: Codable {

    // Pin the on-disk discriminator keys. Renaming one of these raw values
    // would silently strand every persisted row, so the wire-format
    // assertions in MessagePartToolCasesTests / MessagePartThinkingTests are
    // the sentries that catch such drift.
    private enum CodingKeys: String, CodingKey {
        case text, image, audio, thinking, toolCall, toolResult, generatedMedia
        // Legacy discriminators retained for BACKWARD-COMPATIBLE DECODE only
        // (P4b collapse). Persisted rows written before the collapse used these
        // keys; `init(from:)` maps them into `.generatedMedia`. Never emitted by
        // `encode(to:)` — new rows always write `generatedMedia`.
        case generatedImage, generatedVideo
    }

    private enum ImageKeys: String, CodingKey {
        case data, mimeType, placeholderHash
    }

    private enum AudioKeys: String, CodingKey {
        case url, duration, waveform
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
            let placeholderHash = try nested.decodeIfPresent(ImagePlaceholderHash.self, forKey: .placeholderHash)
            self = .image(data: data, mimeType: mimeType, placeholderHash: placeholderHash)
        case .audio:
            let nested = try container.nestedContainer(keyedBy: AudioKeys.self, forKey: .audio)
            self = .audio(
                url: try nested.decode(URL.self, forKey: .url),
                duration: try nested.decode(TimeInterval.self, forKey: .duration),
                waveform: try nested.decodeIfPresent([Float].self, forKey: .waveform)
            )
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
        case .generatedMedia:
            self = .generatedMedia(try container.decode(GeneratedMediaPayload.self, forKey: .generatedMedia))
        case .generatedImage:
            // Back-compat: legacy `generatedImage` rows decode losslessly into
            // `.generatedMedia` so no persisted data is stranded or lost.
            let legacy = try container.decode(ImageMessagePayload.self, forKey: .generatedImage)
            self = .generatedMedia(GeneratedMediaPayload(image: legacy))
        case .generatedVideo:
            // Back-compat: legacy `generatedVideo` rows decode losslessly into
            // `.generatedMedia`.
            let legacy = try container.decode(VideoMessagePayload.self, forKey: .generatedVideo)
            self = .generatedMedia(GeneratedMediaPayload(video: legacy))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType, let placeholderHash):
            var nested = container.nestedContainer(keyedBy: ImageKeys.self, forKey: .image)
            try nested.encode(data, forKey: .data)
            try nested.encode(mimeType, forKey: .mimeType)
            try nested.encodeIfPresent(placeholderHash, forKey: .placeholderHash)
        case .audio(let url, let duration, let waveform):
            var nested = container.nestedContainer(keyedBy: AudioKeys.self, forKey: .audio)
            try nested.encode(url, forKey: .url)
            try nested.encode(duration, forKey: .duration)
            try nested.encodeIfPresent(waveform, forKey: .waveform)
        case .thinking(let text, let signature):
            // Always emit the structured object form; legacy readers in
            // ManifoldSchemaV3 decode through the branch above. A nil
            // signature is omitted to keep persisted rows compact for the
            // common (non-Anthropic) case.
            try container.encode(ThinkingPayload(text: text, signature: signature), forKey: .thinking)
        case .toolCall(let call):
            try container.encode(call, forKey: .toolCall)
        case .toolResult(let result):
            try container.encode(result, forKey: .toolResult)
        case .generatedMedia(let payload):
            try container.encode(payload, forKey: .generatedMedia)
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

    /// The audio payload of this part, or `nil` for non-audio parts.
    public var audioContent: (url: URL, duration: TimeInterval, waveform: [Float]?)? {
        if case .audio(let url, let duration, let waveform) = self {
            return (url, duration, waveform)
        }
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

    /// The ``GeneratedMediaPayload`` of a `.generatedMedia` part, or `nil`
    /// for any other case.
    public var generatedMediaContent: GeneratedMediaPayload? {
        if case .generatedMedia(let p) = self { return p }
        return nil
    }

    /// The ``ImageMessagePayload`` of a `.generatedMedia` image part, or `nil`
    /// for any other case (including video/audio media parts).
    ///
    /// Deprecated shim for the pre-P4b `generatedImage` accessor: pattern-matches
    /// the collapsed `.generatedMedia` case and reconstructs the legacy payload.
    @available(*, deprecated, message: "Use generatedMediaContent and check .kind == .image; reconstruct via GeneratedMediaPayload.asImagePayload if needed.")
    public var generatedImageContent: ImageMessagePayload? {
        if case .generatedMedia(let p) = self { return p.asImagePayload }
        return nil
    }

    /// The ``VideoMessagePayload`` of a `.generatedMedia` video part, or `nil`
    /// for any other case.
    ///
    /// Deprecated shim for the pre-P4b `generatedVideo` accessor.
    @available(*, deprecated, message: "Use generatedMediaContent and check .kind == .video; reconstruct via GeneratedMediaPayload.asVideoPayload if needed.")
    public var generatedVideoContent: VideoMessagePayload? {
        if case .generatedMedia(let p) = self { return p.asVideoPayload }
        return nil
    }

    /// The compact placeholder hash for an uploaded image part, or `nil` for
    /// non-image parts and legacy image parts that pre-date placeholders.
    public var imagePlaceholderHash: ImagePlaceholderHash? {
        if case .image(_, _, let placeholderHash) = self { return placeholderHash }
        return nil
    }

    /// Returns the same image part with a generated placeholder hash when one
    /// is missing. Non-image parts and images that already carry a hash are
    /// returned unchanged.
    public func generatingImagePlaceholderIfNeeded() -> MessagePart {
        guard case .image(let data, let mimeType, let placeholderHash) = self else { return self }
        guard placeholderHash == nil else { return self }
        return .image(
            data: data,
            mimeType: mimeType,
            placeholderHash: ImagePlaceholderHash.generate(from: data)
        )
    }
}
