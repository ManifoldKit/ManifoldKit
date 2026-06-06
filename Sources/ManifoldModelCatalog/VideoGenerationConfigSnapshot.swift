import Foundation

/// Persistence-layer mirror of ``VideoGenerationConfig``.
///
/// Held by ``VideoMessagePayload`` so saved conversation history can render —
/// or regenerate — a video with the exact parameters that produced it.
///
/// ## Why a separate type?
///
/// ``VideoGenerationConfig`` is the *runtime* shape. Backends read fields
/// from it and may grow new ones over time. Decoupling persistence from
/// runtime keeps two concerns from drifting into each other:
///
/// - Adding a new runtime knob does not silently change the on-disk wire
///   format of every persisted video message.
/// - Renaming or restructuring a runtime field does not strand persisted
///   rows; the snapshot type stays stable and adopts changes deliberately
///   via an explicit Codable migration.
public struct VideoGenerationConfigSnapshot: Sendable, Hashable {

    /// Duration in seconds, as recorded at generation time.
    public var duration: Int

    /// Aspect ratio string recorded at generation time (e.g. `"16:9"`).
    public var aspectRatio: String

    /// Output width in pixels, or `nil` when the backend chose its default.
    public var width: Int?

    /// Output height in pixels, or `nil` when the backend chose its default.
    public var height: Int?

    /// Local file URL of the source image used for image-to-video, if any.
    public var sourceImageURL: URL?

    public init(
        duration: Int,
        aspectRatio: String,
        width: Int? = nil,
        height: Int? = nil,
        sourceImageURL: URL? = nil
    ) {
        self.duration = duration
        self.aspectRatio = aspectRatio
        self.width = width
        self.height = height
        self.sourceImageURL = sourceImageURL
    }

    /// Captures the current runtime configuration into a persistable snapshot.
    public init(from config: VideoGenerationConfig) {
        self.duration = config.duration
        self.aspectRatio = config.aspectRatio
        self.width = config.width
        self.height = config.height
        self.sourceImageURL = config.sourceImageURL
    }

    /// Rehydrates a runtime ``VideoGenerationConfig`` from this snapshot.
    public func toConfig() -> VideoGenerationConfig {
        VideoGenerationConfig(
            duration: duration,
            aspectRatio: aspectRatio,
            width: width,
            height: height,
            sourceImageURL: sourceImageURL
        )
    }
}

// MARK: - Codable

extension VideoGenerationConfigSnapshot: Codable {

    private enum CodingKeys: String, CodingKey {
        case duration, aspectRatio, width, height, sourceImageURL
        // Legacy key written by the original xAI-shaped snapshot.
        case resolution
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.duration = try c.decode(Int.self, forKey: .duration)
        self.aspectRatio = try c.decode(String.self, forKey: .aspectRatio)
        self.width = try c.decodeIfPresent(Int.self, forKey: .width)
        self.height = try c.decodeIfPresent(Int.self, forKey: .height)
        self.sourceImageURL = try c.decodeIfPresent(URL.self, forKey: .sourceImageURL)
        // Legacy `resolution` string rows decode to nil width/height (backend default).
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(duration, forKey: .duration)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(sourceImageURL, forKey: .sourceImageURL)
    }
}
