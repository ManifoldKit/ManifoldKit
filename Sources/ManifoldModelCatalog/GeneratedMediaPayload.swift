import Foundation

/// The modality of a backend-generated media artifact.
///
/// One-shot artifact modalities only. Realtime/duplex streams are explicitly
/// out of scope — a generated-media artifact has the same lifecycle whether it
/// is an image, a video, or a one-shot audio clip (TTS).
///
/// Out-of-tree consumers can introduce additional modalities by carrying their
/// own backend + config and persisting under ``GeneratedMediaPayload`` with a
/// modality they own; the persisted ``GeneratedMediaPayload`` stays the single
/// shape the chat transcript renders.
public enum MediaKind: String, Sendable, Codable, Hashable, CaseIterable {
    case image
    case video
    /// One-shot audio artifact (e.g. text-to-speech output). Music generation
    /// lives as a consumer/companion extension, not a core modality.
    case audio
}

/// Unified persisted record of a single backend-generated media artifact,
/// attached to a ``MessagePart/generatedMedia(_:)``.
///
/// Subsumes the legacy ``ImageMessagePayload`` and ``VideoMessagePayload`` —
/// it can losslessly represent everything those carried — and is generic
/// enough that a new one-shot modality (audio/TTS today; out-of-tree music
/// later) needs no new ``MessagePart`` case.
///
/// ## Why URL instead of inline bytes?
///
/// Generated media (1–4 MB PNGs, 10–100 MB videos, audio clips) would balloon
/// `contentPartsJSON` if stored inline. The binary is owned by the host app's
/// storage strategy; this payload only references it by file URL.
///
/// ## Lossless legacy representation
///
/// - Image rows carry their original ``ImageGenerationConfigSnapshot`` in
///   ``imageConfig`` and round-trip via ``init(image:)`` / ``asImagePayload``.
/// - Video rows carry their original ``VideoGenerationConfigSnapshot`` in
///   ``videoConfig`` and round-trip via ``init(video:)`` / ``asVideoPayload``.
///
/// New modalities (audio) use the generic optional metadata fields
/// (``durationSeconds``, ``format``, ``width``/``height``) without a typed
/// config slot.
public struct GeneratedMediaPayload: Sendable, Codable, Equatable, Hashable {

    /// Which media modality this artifact is.
    public var kind: MediaKind

    /// The prompt the user submitted to produce this artifact.
    public var prompt: String

    /// File URL (in the app container) of the produced binary.
    public var url: URL

    /// Identifier of the model/service that produced this artifact. Free-form
    /// because identifiers vary by backend (HF repo path, GGUF basename,
    /// system model name, cloud service id).
    public var modelIdentifier: String

    /// When the artifact was produced.
    public var generatedAt: Date

    // MARK: Generic optional metadata

    /// MIME type / container format of the artifact (e.g. `"image/png"`,
    /// `"video/mp4"`, `"audio/mpeg"`). `nil` when the consumer derives it from
    /// the URL extension.
    public var format: String?

    /// Output width in pixels (image/video), or `nil` when not applicable.
    public var width: Int?

    /// Output height in pixels (image/video), or `nil` when not applicable.
    public var height: Int?

    /// Duration in seconds (video/audio), or `nil` for still images.
    public var durationSeconds: Double?

    // MARK: Lossless legacy config snapshots

    /// The original image generation parameters, present only for
    /// ``MediaKind/image`` rows migrated from ``ImageMessagePayload``.
    public var imageConfig: ImageGenerationConfigSnapshot?

    /// The original video generation parameters, present only for
    /// ``MediaKind/video`` rows migrated from ``VideoMessagePayload``.
    public var videoConfig: VideoGenerationConfigSnapshot?

    public init(
        kind: MediaKind,
        prompt: String,
        url: URL,
        modelIdentifier: String,
        generatedAt: Date = Date(),
        format: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil,
        imageConfig: ImageGenerationConfigSnapshot? = nil,
        videoConfig: VideoGenerationConfigSnapshot? = nil
    ) {
        self.kind = kind
        self.prompt = prompt
        self.url = url
        self.modelIdentifier = modelIdentifier
        self.generatedAt = generatedAt
        self.format = format
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.imageConfig = imageConfig
        self.videoConfig = videoConfig
    }

    // MARK: - Codable (tolerant)

    // Custom Codable so a row written by an older build that omits any of the
    // optional metadata/config slots decodes cleanly, and so absent fields are
    // never force-encoded as `null`.
    private enum CodingKeys: String, CodingKey {
        case kind, prompt, url, modelIdentifier, generatedAt
        case format, width, height, durationSeconds
        case imageConfig, videoConfig
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(MediaKind.self, forKey: .kind)
        self.prompt = try c.decode(String.self, forKey: .prompt)
        self.url = try c.decode(URL.self, forKey: .url)
        self.modelIdentifier = try c.decode(String.self, forKey: .modelIdentifier)
        self.generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        self.format = try c.decodeIfPresent(String.self, forKey: .format)
        self.width = try c.decodeIfPresent(Int.self, forKey: .width)
        self.height = try c.decodeIfPresent(Int.self, forKey: .height)
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        self.imageConfig = try c.decodeIfPresent(ImageGenerationConfigSnapshot.self, forKey: .imageConfig)
        self.videoConfig = try c.decodeIfPresent(VideoGenerationConfigSnapshot.self, forKey: .videoConfig)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(url, forKey: .url)
        try c.encode(modelIdentifier, forKey: .modelIdentifier)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encodeIfPresent(format, forKey: .format)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(imageConfig, forKey: .imageConfig)
        try c.encodeIfPresent(videoConfig, forKey: .videoConfig)
    }
}

// MARK: - Lossless legacy bridges

extension GeneratedMediaPayload {

    /// Builds a generated-media payload that losslessly represents a legacy
    /// ``ImageMessagePayload``. The image config snapshot rides in
    /// ``imageConfig`` and the pixel dimensions are mirrored into
    /// ``width``/``height`` for generic consumers.
    public init(image payload: ImageMessagePayload) {
        self.init(
            kind: .image,
            prompt: payload.prompt,
            url: payload.imageURL,
            modelIdentifier: payload.modelIdentifier,
            generatedAt: payload.generatedAt,
            width: payload.generationConfig.width,
            height: payload.generationConfig.height,
            imageConfig: payload.generationConfig
        )
    }

    /// Builds a generated-media payload that losslessly represents a legacy
    /// ``VideoMessagePayload``. The video config snapshot rides in
    /// ``videoConfig``; dimensions and duration are mirrored for generic
    /// consumers.
    public init(video payload: VideoMessagePayload) {
        self.init(
            kind: .video,
            prompt: payload.prompt,
            url: payload.videoURL,
            modelIdentifier: payload.modelIdentifier,
            generatedAt: payload.generatedAt,
            width: payload.generationConfig.width,
            height: payload.generationConfig.height,
            durationSeconds: Double(payload.generationConfig.duration),
            videoConfig: payload.generationConfig
        )
    }

    /// Reconstructs the legacy ``ImageMessagePayload`` from an image-kind
    /// payload that carries an ``imageConfig``. Returns `nil` for non-image
    /// payloads or image payloads with no captured config snapshot.
    public var asImagePayload: ImageMessagePayload? {
        guard kind == .image, let imageConfig else { return nil }
        return ImageMessagePayload(
            prompt: prompt,
            imageURL: url,
            modelIdentifier: modelIdentifier,
            generationConfig: imageConfig,
            generatedAt: generatedAt
        )
    }

    /// Reconstructs the legacy ``VideoMessagePayload`` from a video-kind
    /// payload that carries a ``videoConfig``. Returns `nil` for non-video
    /// payloads or video payloads with no captured config snapshot.
    public var asVideoPayload: VideoMessagePayload? {
        guard kind == .video, let videoConfig else { return nil }
        return VideoMessagePayload(
            prompt: prompt,
            videoURL: url,
            modelIdentifier: modelIdentifier,
            generationConfig: videoConfig,
            generatedAt: generatedAt
        )
    }
}
