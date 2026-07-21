import Foundation

/// Configuration for a one-shot text-to-speech (TTS) generation request.
///
/// The request shape for the audio (TTS) modality. Mirrors the role
/// ``ImageGenerationConfig`` plays for image generation: a single value type
/// the caller hands a TTS backend so each backend need not invent its own
/// request shape. Backends that do not honour a field silently ignore it,
/// matching the ``ImageGenerationConfig`` convention.
///
/// One-shot only — this produces a single audio artifact persisted as a
/// ``GeneratedMediaPayload`` with ``MediaKind/audio``. Realtime/duplex speech
/// is out of scope. No backend conformance ships in core; this is the
/// modality's config surface only.
public struct SpeechGenerationConfig: Sendable, Codable, Equatable, Hashable {

    /// The text to synthesise into speech.
    public var text: String

    /// Identifier of the voice to use. Free-form because voice identifiers vary
    /// by backend (system voice id, cloud voice name). `nil` lets the backend
    /// use its default voice.
    public var voice: String?

    /// Speaking rate multiplier. `1.0` is the backend's natural rate; values
    /// above speed up, below slow down. `nil` uses the backend default.
    public var rate: Float?

    /// Pitch multiplier. `1.0` is the backend's natural pitch; values above
    /// raise, below lower. `nil` uses the backend default.
    public var pitch: Float?

    /// Destination directory the backend should write the produced audio into.
    /// `nil` means *backend's discretion* (typically the temporary directory).
    /// Mirrors ``ImageGenerationConfig/outputDirectory``.
    public var outputDirectory: URL?

    public init(
        text: String,
        voice: String? = nil,
        rate: Float? = nil,
        pitch: Float? = nil,
        outputDirectory: URL? = nil
    ) {
        self.text = text
        self.voice = voice
        self.rate = rate
        self.pitch = pitch
        self.outputDirectory = outputDirectory
    }

    // MARK: - Codable

    // Custom Codable so older payloads that omit optional knobs decode to `nil`
    // rather than failing, and absent fields never force-encode as `null`.
    private enum CodingKeys: String, CodingKey {
        case text, voice, rate, pitch, outputDirectory
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decode(String.self, forKey: .text)
        self.voice = try c.decodeIfPresent(String.self, forKey: .voice)
        self.rate = try c.decodeIfPresent(Float.self, forKey: .rate)
        self.pitch = try c.decodeIfPresent(Float.self, forKey: .pitch)
        self.outputDirectory = try c.decodeIfPresent(URL.self, forKey: .outputDirectory)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(voice, forKey: .voice)
        try c.encodeIfPresent(rate, forKey: .rate)
        try c.encodeIfPresent(pitch, forKey: .pitch)
        try c.encodeIfPresent(outputDirectory, forKey: .outputDirectory)
    }
}
