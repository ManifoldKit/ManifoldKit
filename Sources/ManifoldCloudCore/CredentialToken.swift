#if Ollama || CloudSaaS
import Foundation

/// Opaque wrapper for cloud-provider API keys that suppresses accidental
/// logging.
///
/// Raw `String` API keys flow through enough code paths
/// (`os.Logger` interpolation, `XCTAssertEqual` diagnostics, crash reports,
/// `String(describing:)` panics) that any of them could leak the raw token.
/// `CredentialToken`'s `description` / `debugDescription` always return
/// `"<redacted>"` — the underlying value is only exposed through the explicit
/// ``reveal()`` accessor.
///
/// This is **not** memory zeroing; that responsibility stays with
/// ``SecureBytes``. `CredentialToken` is a logging hygiene wrapper. Both
/// can be combined when the caller already holds a ``SecureBytes``.
///
/// ```swift
/// let token = CredentialToken("sk-…")
/// Log.network.debug("auth header set: \(token)")  // logs "<redacted>"
/// request.setValue("Bearer \(token.reveal())", forHTTPHeaderField: "Authorization")
/// ```
public struct CredentialToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    /// Convenience for optional keys. Returns `nil` when the input is `nil`
    /// or empty so callers can short-circuit authentication header writes.
    public init?(optional raw: String?) {
        guard let raw, !raw.isEmpty else { return nil }
        self.raw = raw
    }

    /// Reveal the underlying value. Use only at request-construction time;
    /// never log the result.
    public func reveal() -> String { raw }

    /// Whether the underlying token is empty.
    public var isEmpty: Bool { raw.isEmpty }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}
#endif
