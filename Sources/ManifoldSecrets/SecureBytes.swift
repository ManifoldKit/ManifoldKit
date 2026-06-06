import Darwin
import Foundation

/// Stores a secret in a heap-allocated mutable buffer that is zeroed via
/// `memset_s` on deallocation.
///
/// This reduces the window during which API keys linger in freed memory once a
/// backend is unloaded or reconfigured. `memset_s` is used instead of plain
/// `memset` because the C standard allows optimising-compilers to elide a
/// `memset` call whose result is never read; `memset_s` carries a conformance
/// obligation that prevents that elision.
///
/// **Scope of the guarantee**: only the bytes owned by this object are zeroed.
/// Any `String` value returned by ``stringValue`` is a separate Swift-managed
/// copy and is not covered.
///
/// `SecureBytes` is `package`-visible so that both `ManifoldInference`
/// (``KeychainService``) and `ManifoldBackends` (``SSECloudBackend``) can use
/// it without exposing it on the public API surface.
package final class SecureBytes: @unchecked Sendable {

    private let buffer: UnsafeMutableBufferPointer<UInt8>

    package init?(_ string: String) {
        let utf8 = string.utf8
        guard !utf8.isEmpty else { return nil }
        buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: utf8.count)
        _ = buffer.initialize(from: utf8)
    }

    /// Initializes from raw bytes without creating a `String` intermediate.
    ///
    /// Use this when reading from ``KeychainService`` (which returns `Data`
    /// from `SecItemCopyMatching`) to avoid a plain-Swift-String heap copy.
    package init?(_ data: Data) {
        guard !data.isEmpty else { return nil }
        buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: data.count)
        data.withUnsafeBytes { src in
            _ = buffer.initialize(from: src.bindMemory(to: UInt8.self))
        }
    }

    /// Initializes by copying another ``SecureBytes`` instance's buffer.
    ///
    /// Use this when you need an independently-zeroed copy of an existing
    /// secret (e.g. a per-call clone from a long-lived ephemeral key) without
    /// round-tripping through a plain Swift `String`. The source's lifetime is
    /// unchanged; both buffers are zeroed independently on `deinit`.
    package init?(copying other: SecureBytes) {
        guard !other.buffer.isEmpty else { return nil }
        buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: other.buffer.count)
        _ = buffer.initialize(from: UnsafeBufferPointer(other.buffer))
    }

    /// Returns the stored bytes decoded as a UTF-8 string.
    ///
    /// > Warning: The returned `String` is a fresh Swift heap allocation that
    /// > is **not** covered by the `memset_s` guarantee. Call this only at the
    /// > final boundary where a `String` is structurally required (e.g.
    /// > `URLRequest.setValue(_:forHTTPHeaderField:)`) and let the value
    /// > immediately fall out of scope. Avoid storing it in a property or
    /// > capturing it in a long-lived closure.
    package var stringValue: String {
        String(decoding: buffer, as: UTF8.self)
    }

    #if DEBUG
    /// Test-only inspection seam fired from `deinit` *after* `memset_s` has
    /// run but *before* `deallocate`, so a test can observe whether the
    /// buffer was actually zeroed. The closure receives an immutable view
    /// of the still-valid backing buffer; capturing the pointer past the
    /// closure's return is undefined behaviour. Compiled out of release
    /// builds — production code paths are unchanged.
    var _testingOnZeroed: ((UnsafeBufferPointer<UInt8>) -> Void)?
    #endif

    deinit {
        _ = memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
        #if DEBUG
        if let probe = _testingOnZeroed {
            probe(UnsafeBufferPointer(buffer))
        }
        #endif
        buffer.deallocate()
    }
}
