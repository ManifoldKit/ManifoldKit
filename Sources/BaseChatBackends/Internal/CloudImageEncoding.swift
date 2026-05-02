import Foundation
import BaseChatInference

/// Shared image-encoding helpers for cloud backends that send images as
/// content blocks (Anthropic Messages API, OpenAI Chat Completions
/// `image_url`, etc.).
///
/// Kept minimal on purpose — base64 encoding plus light validation. No
/// resizing or re-encoding lives here today; if a future provider rejects
/// large images we can layer that in without rewriting call sites.
///
/// Lane B (OpenAI image_url) shares this helper for the base64 string +
/// per-turn cap. The cap value itself differs per provider: Anthropic
/// rejects more than 5 images per turn, OpenAI tolerates more, so each
/// caller passes its own ``maxImages``.
enum CloudImageEncoding {

    /// MIME types Anthropic's vision endpoint accepts. Matches the
    /// `image/png`, `image/jpeg`, `image/gif`, `image/webp` allowlist
    /// documented for the Messages API.
    static let anthropicSupportedMimeTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/jpg",
        "image/gif",
        "image/webp",
    ]

    /// MIME types OpenAI's Chat Completions `image_url` accepts.
    static let openAISupportedMimeTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/jpg",
        "image/gif",
        "image/webp",
    ]

    /// Returns the base64-encoded payload for a `MessagePart.image` using
    /// the same encoding both Anthropic and OpenAI expect (no line breaks,
    /// no padding tweaks).
    static func base64String(from data: Data) -> String {
        data.base64EncodedString()
    }

    /// Returns a `data:<mime>;base64,<payload>` URI suitable for providers
    /// that accept inline base64 images via a single URL field (OpenAI
    /// `image_url`, etc.). The MIME type is forwarded verbatim — callers
    /// validate against the per-provider allowlist above when needed.
    static func dataURI(data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(base64String(from: data))"
    }

    /// Counts every `.image` part across `messages`. Used by callers that
    /// enforce a per-request image cap (Anthropic = 5 per *turn*, but the
    /// caller decides whether the cap applies turn-by-turn or
    /// across the whole request).
    static func imageCount(in messages: [StructuredMessage]) -> Int {
        messages.reduce(0) { acc, message in
            acc + message.parts.reduce(0) { count, part in
                if case .image = part { return count + 1 }
                return count
            }
        }
    }

    /// Counts `.image` parts within a single turn.
    static func imageCount(in parts: [MessagePart]) -> Int {
        parts.reduce(0) { count, part in
            if case .image = part { return count + 1 }
            return count
        }
    }
}
