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
///
/// Mirrors the field shape exactly today; future divergence is allowed
/// without touching ``VideoGenerationConfig``.
public struct VideoGenerationConfigSnapshot: Sendable, Hashable {

    /// Duration in seconds, as recorded at generation time.
    public var duration: Int

    /// Raw value of ``VideoGenerationConfig/AspectRatio`` (e.g. `"16:9"`).
    public var aspectRatio: String

    /// Raw value of ``VideoGenerationConfig/Resolution`` (e.g. `"720p"`).
    public var resolution: String

    /// Local file URL of the source image used for image-to-video mode, if any.
    public var sourceImageURL: URL?

    public init(
        duration: Int,
        aspectRatio: String,
        resolution: String,
        sourceImageURL: URL? = nil
    ) {
        self.duration = duration
        self.aspectRatio = aspectRatio
        self.resolution = resolution
        self.sourceImageURL = sourceImageURL
    }

    /// Captures the current runtime configuration into a persistable
    /// snapshot. Used by the persistence layer at the moment a
    /// ``VideoMessagePayload`` is created.
    public init(from config: VideoGenerationConfig) {
        self.duration = config.duration
        self.aspectRatio = config.aspectRatio.rawValue
        self.resolution = config.resolution.rawValue
        self.sourceImageURL = config.sourceImageURL
    }

    /// Rehydrates a runtime ``VideoGenerationConfig`` from this snapshot.
    /// Used when replaying a generation from history (e.g. a "regenerate
    /// with the same settings" affordance).
    ///
    /// Falls back to ``VideoGenerationConfig`` defaults when the stored raw
    /// values do not match any current enum case — tolerates enum additions
    /// across app versions.
    public func toConfig() -> VideoGenerationConfig {
        VideoGenerationConfig(
            duration: duration,
            aspectRatio: VideoGenerationConfig.AspectRatio(rawValue: aspectRatio) ?? .landscape,
            resolution: VideoGenerationConfig.Resolution(rawValue: resolution) ?? .hd,
            sourceImageURL: sourceImageURL
        )
    }
}

// MARK: - Codable

extension VideoGenerationConfigSnapshot: Codable {

    // Custom Codable so older persisted rows that pre-date `sourceImageURL`
    // decode to `nil` rather than failing the whole row, and so absent
    // fields never get force-encoded as `null`.
    private enum CodingKeys: String, CodingKey {
        case duration, aspectRatio, resolution, sourceImageURL
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.duration = try c.decode(Int.self, forKey: .duration)
        self.aspectRatio = try c.decode(String.self, forKey: .aspectRatio)
        self.resolution = try c.decode(String.self, forKey: .resolution)
        self.sourceImageURL = try c.decodeIfPresent(URL.self, forKey: .sourceImageURL)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(duration, forKey: .duration)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encode(resolution, forKey: .resolution)
        try c.encodeIfPresent(sourceImageURL, forKey: .sourceImageURL)
    }
}
