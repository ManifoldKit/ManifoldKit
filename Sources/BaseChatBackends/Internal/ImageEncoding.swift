import Foundation

/// Helpers for embedding ``MessagePart/image(data:mimeType:)`` payloads in
/// cloud-provider request bodies.
///
/// Cloud APIs that accept images on the wire expect either a remote URL or a
/// base64-encoded data URI. BaseChatKit always carries images as raw `Data`
/// in ``MessagePart``, so backends format them as `data:` URIs at the
/// request-building boundary. This helper centralises the encoding so the
/// formatting stays identical across providers and tests can assert against
/// a single canonical shape.
///
/// The helper is intentionally minimal — base64 only, no resizing or
/// re-encoding. Backends that need to clamp pixel size or strip metadata
/// should do it before calling these helpers.
enum ImageEncoding {

    /// Returns a `data:<mime>;base64,<payload>` URI suitable for any provider
    /// that accepts inline base64 images (OpenAI `image_url`, Anthropic
    /// `image.source.data`, etc.).
    ///
    /// The MIME type is forwarded verbatim — callers are responsible for
    /// passing a value the upstream API understands (`image/png`,
    /// `image/jpeg`, `image/webp`, `image/gif`).
    static func dataURI(data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}
