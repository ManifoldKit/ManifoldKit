import Foundation

/// Persisted record of a single backend-generated video, attached to a
/// ``MessagePart/generatedVideo(_:)``.
///
/// Distinct from ``ImageMessagePayload`` — this type carries a
/// *backend-produced video output*, referenced by file URL (the binary lives
/// on disk in the app container) and tagged with the parameters that produced
/// it.
///
/// ## Why URL instead of inline bytes?
///
/// Generated videos are typically 10–100 MB files. Storing the bytes in
/// ``ManifoldSchemaV4/ChatMessage/contentPartsJSON`` would balloon the
/// JSON payload size for every saved row and make pagination expensive.
/// The video binary is owned by the host app's storage strategy; this
/// payload only references it.
public struct VideoMessagePayload: Sendable, Codable, Hashable {

    /// The prompt the user submitted to produce this video.
    public var prompt: String

    /// File URL (in the app container) of the produced video binary.
    public var videoURL: URL

    /// Identifier of the backend service that produced this video. Free-form
    /// because service identifiers vary by provider.
    public var modelIdentifier: String

    /// Snapshot of the generation parameters used to produce this video.
    /// Captured at generation time so a "regenerate with same settings"
    /// affordance remains meaningful even after the runtime config evolves.
    public var generationConfig: VideoGenerationConfigSnapshot

    /// When the video was produced.
    public var generatedAt: Date

    public init(
        prompt: String,
        videoURL: URL,
        modelIdentifier: String,
        generationConfig: VideoGenerationConfigSnapshot,
        generatedAt: Date = Date()
    ) {
        self.prompt = prompt
        self.videoURL = videoURL
        self.modelIdentifier = modelIdentifier
        self.generationConfig = generationConfig
        self.generatedAt = generatedAt
    }
}
