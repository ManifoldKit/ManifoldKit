import Foundation
import os
import ManifoldInference

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
package enum CloudImageEncoding {

    /// MIME types Anthropic's vision endpoint accepts. Matches the
    /// `image/png`, `image/jpeg`, `image/gif`, `image/webp` allowlist
    /// documented for the Messages API.
    package static let anthropicSupportedMimeTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/jpg",
        "image/gif",
        "image/webp",
    ]

    /// Returns the base64-encoded payload for a `MessagePart.image` using
    /// the same encoding both Anthropic and OpenAI expect (no line breaks,
    /// no padding tweaks).
    package static func base64String(from data: Data) -> String {
        let encoded = data.base64EncodedString()
        // Read the hook under the lock so a concurrent `setEncodeHook` from a
        // test cannot race the optional-closure pointer (a Swift 6
        // memory-safety violation). The closure itself runs outside the lock.
        _encodeHook.withLock { $0 }?()
        return encoded
    }

    /// Lock-guarded storage for the test-injection hook.
    ///
    /// Mirrors `GenerationQueue.toolDispatchLogHook`: production callers
    /// never set this; it exists so tests can count how many times a cloud
    /// backend re-encodes the same `MessagePart.image` payload across turns
    /// without instrumenting the encoder itself. Tests must reset it in
    /// `tearDown` to avoid cross-test leakage. See
    /// `CloudImageEncodeCountTests` for the invariant the perf-audit plan
    /// (PR-α work unit α-3) is grounding on.
    ///
    /// The previous `nonisolated(unsafe) static var` raced when cloud backends
    /// encoded images on concurrent threads while a test mutated the hook. An
    /// `OSAllocatedUnfairLock` (available below the macOS 15 / iOS 18 floor)
    /// makes every read/write atomic without an actor hop on the hot path.
    private static let _encodeHook =
        OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    /// Installs (or clears, with `nil`) the test-injection hook race-free.
    ///
    /// Keeps the readable `CloudImageEncoding.setEncodeHook { ... }` call shape
    /// at test sites while routing the write through the lock.
    package static func setEncodeHook(_ hook: (@Sendable () -> Void)?) {
        _encodeHook.withLock { $0 = hook }
    }

    /// Returns a `data:` URI (RFC 2397) suitable for OpenAI's
    /// `image_url.url` field — `data:<mime>;base64,<payload>`. OpenAI also
    /// accepts public `https://` URLs there, but we always have the bytes
    /// in-process at this layer, so the data URI is the simplest path.
    ///
    /// The MIME type is passed through untouched. OpenAI's vision endpoint
    /// accepts at least `image/png`, `image/jpeg`, `image/gif`, and
    /// `image/webp`; an exotic value will surface as an upstream 400, which
    /// matches the same failure mode persisted images would already have on
    /// other backends.
    package static func dataURI(data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(base64String(from: data))"
    }

    /// Counts every `.image` part across `messages`. Used by callers that
    /// enforce a per-request image cap (Anthropic = 5 per *turn*, but the
    /// caller decides whether the cap applies turn-by-turn or
    /// across the whole request).
    package static func imageCount(in messages: [StructuredMessage]) -> Int {
        messages.reduce(0) { acc, message in
            acc + message.parts.reduce(0) { count, part in
                if case .image = part { return count + 1 }
                return count
            }
        }
    }

    /// Counts `.image` parts within a single turn.
    package static func imageCount(in parts: [MessagePart]) -> Int {
        parts.reduce(0) { count, part in
            if case .image = part { return count + 1 }
            return count
        }
    }
}
