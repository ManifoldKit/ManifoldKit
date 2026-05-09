import Foundation

/// Persisted record of a single backend-generated image, attached to a
/// ``MessagePart/generatedImage(_:)``.
///
/// Distinct from ``MessagePart/image(data:mimeType:)`` — that case carries
/// raw image bytes uploaded by the *user* as input to a multimodal model.
/// This type carries a *backend-produced output* image, referenced by file
/// URL (the binary lives on disk in the app container) and tagged with the
/// model and parameters that produced it.
///
/// ## Why URL instead of inline bytes?
///
/// Generated images are typically 1–4 MB PNGs. Storing the bytes in
/// ``ManifoldSchemaV4/ChatMessage/contentPartsJSON`` would balloon the
/// JSON payload size for every saved row and make pagination expensive.
/// The image binary is owned by the host app's storage strategy; this
/// payload only references it.
public struct ImageMessagePayload: Sendable, Codable, Hashable {

    /// The prompt the user submitted to produce this image.
    public var prompt: String

    /// File URL (in the app container) of the produced image binary.
    public var imageURL: URL

    /// Identifier of the model that produced this image. Free-form because
    /// model identifiers vary by backend (HF repo path, GGUF file basename,
    /// system model name).
    public var modelIdentifier: String

    /// Snapshot of the generation parameters used to produce this image.
    /// Captured at generation time so a "regenerate with same settings"
    /// affordance remains meaningful even after the runtime config evolves.
    public var generationConfig: ImageGenerationConfigSnapshot

    /// When the image was produced.
    public var generatedAt: Date

    public init(
        prompt: String,
        imageURL: URL,
        modelIdentifier: String,
        generationConfig: ImageGenerationConfigSnapshot,
        generatedAt: Date = Date()
    ) {
        self.prompt = prompt
        self.imageURL = imageURL
        self.modelIdentifier = modelIdentifier
        self.generationConfig = generationConfig
        self.generatedAt = generatedAt
    }
}
