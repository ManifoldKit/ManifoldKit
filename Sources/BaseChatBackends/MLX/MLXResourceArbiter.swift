#if MLX
import Foundation
import MLX
import os
import BaseChatInference

/// Coordinates MLX's process-global GPU buffer cache across multiple
/// `MLXBackend` instances in the same host.
///
/// `MLX.Memory.cacheLimit` and `MLX.Memory.clearCache()` operate on a single
/// process-wide pool. A naive multi-MLX setup — for example, a chat backend
/// plus an embeddings backend, or two `MLXBackend`s loaded for A/B comparison
/// — has the second `loadModel` overwrite the first's `cacheLimit`, and any
/// `clearCache()` from one backend evicts pooled buffers that other backends
/// depend on for KV-cache reuse. Both behaviours corrupt KV reuse silently.
///
/// The arbiter solves this by accumulating per-backend cache claims and
/// programming `MLX.Memory.cacheLimit` to the **sum** of all active claims.
/// `clearCache()` is only invoked on the **last** release — until every MLX
/// backend has unloaded, the cache stays populated so other live backends
/// keep their residue.
///
/// ## Metallib guard
///
/// Every call into `MLX.Memory` is conditioned on the caller having completed
/// at least one successful `loadModelContainer` (the proxy is the caller — it
/// only invokes `claim`/`release` after that gate). The arbiter itself trusts
/// that contract and does not attempt to detect uninitialised runtime state.
/// Calling `MLX.Memory.cacheLimit` before any model has loaded would trip a
/// "Failed to load default metallib" abort in plain `swift test` environments.
///
/// ## Usage
///
/// ```swift
/// // After loadModelContainer succeeds:
/// await MLXResourceArbiter.shared.claim(
///     backendID: backendID,
///     requestedCacheBytes: cachePolicy.resolvedBytes()
/// )
///
/// // In unloadModel / cleanup:
/// await MLXResourceArbiter.shared.release(backendID: backendID)
/// ```
///
/// All `MLXBackend` instances must coordinate through `shared`; mixing
/// arbitrated and direct `MLX.Memory.*` calls in the same process defeats the
/// accounting.
public actor MLXResourceArbiter {

    /// Stable per-backend identity used as the claim key.
    public typealias BackendID = UUID

    public static let shared = MLXResourceArbiter()

    private static let logger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "mlx-arbiter"
    )

    /// Active claims, keyed by backend identity. Value is the requested
    /// cache-bytes contribution from that backend.
    private var claims: [BackendID: Int] = [:]

    // MARK: - Test seams

    /// Closure invoked to set MLX's process-global `cacheLimit`. Production
    /// hits `MLX.Memory.cacheLimit = bytes`. Tests inject a stub so the
    /// arbiter's accounting logic can run in `swift test` (where the
    /// metallib isn't compiled and a real `MLX.Memory` access aborts the
    /// process).
    private var setCacheLimit: @Sendable (Int) -> Void = { Memory.cacheLimit = $0 }

    /// Closure invoked to clear MLX's process-global pool. Mirrors
    /// `setCacheLimit` for the same reason.
    private var clearCache: @Sendable () -> Void = { Memory.clearCache() }

    public init() {}

    /// Test-only initialiser that lets the suite inject its own
    /// `setCacheLimit` / `clearCache` recorders. Not exposed on `shared` —
    /// tests that need an isolated arbiter construct a fresh instance.
    init(
        setCacheLimit: @escaping @Sendable (Int) -> Void,
        clearCache: @escaping @Sendable () -> Void
    ) {
        self.setCacheLimit = setCacheLimit
        self.clearCache = clearCache
    }

    /// Records a cache-bytes claim for `backendID` and reprograms
    /// `MLX.Memory.cacheLimit` to the sum of all current claims.
    ///
    /// If `backendID` already has a claim, the existing value is replaced —
    /// callers can re-issue with a different policy without an explicit
    /// release first. Negative values are clamped to zero.
    ///
    /// - Important: Caller must have completed a successful
    ///   `loadModelContainer` before invoking this. See the metallib guard
    ///   note in the type-level documentation.
    public func claim(backendID: BackendID, requestedCacheBytes: Int) {
        let bytes = max(0, requestedCacheBytes)
        claims[backendID] = bytes
        let total = claims.values.reduce(0, +)
        setCacheLimit(total)
        Self.logger.info(
            "MLX arbiter claim: backend=\(backendID, privacy: .public) bytes=\(bytes) total=\(total) activeClaims=\(self.claims.count)"
        )
    }

    /// Releases the claim for `backendID`. If any other backends still hold
    /// claims, `MLX.Memory.cacheLimit` is reduced to the new sum and pooled
    /// buffers are left in place (they belong to the surviving backends).
    /// On the last release, `MLX.Memory.clearCache()` is invoked so freed
    /// buffers return to the OS.
    ///
    /// Idempotent: releasing a backend that holds no claim is a no-op.
    public func release(backendID: BackendID) {
        guard claims.removeValue(forKey: backendID) != nil else {
            return
        }
        if claims.isEmpty {
            clearCache()
            Self.logger.info("MLX arbiter release: last backend, clearCache invoked")
        } else {
            let total = claims.values.reduce(0, +)
            setCacheLimit(total)
            Self.logger.info(
                "MLX arbiter release: backend=\(backendID, privacy: .public) remaining=\(self.claims.count) total=\(total)"
            )
        }
    }

    /// Emergency hatch: drops every claim and calls `MLX.Memory.clearCache()`.
    ///
    /// Reserved for memory-pressure handlers that need to force a global
    /// eviction across all MLX backends. After this returns, every backend
    /// must re-claim before its next generate call would be safe.
    public func clearAll() {
        let count = claims.count
        claims.removeAll(keepingCapacity: false)
        clearCache()
        Self.logger.info("MLX arbiter clearAll: dropped \(count) claims")
    }

    // MARK: - Test seams

    /// Test-only read of the active claim count. Used by
    /// `MLXResourceArbiterTests` to verify accounting without exposing the
    /// claims map.
    func _activeClaimCountForTesting() -> Int {
        claims.count
    }

    /// Test-only read of the summed claim bytes. Callers that exercise the
    /// arbiter without a live MLX runtime must use this rather than reading
    /// `MLX.Memory.cacheLimit` (which requires the metallib).
    func _totalClaimedBytesForTesting() -> Int {
        claims.values.reduce(0, +)
    }
}
#endif
