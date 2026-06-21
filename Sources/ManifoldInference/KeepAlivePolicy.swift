import Foundation

/// Policy that controls how long an idle resident model is kept in memory.
///
/// When ``idleTimeout`` is non-nil, ``InferenceService`` starts a background
/// watch task after each successful model load. The task polls the generation
/// queue's ``GenerationQueue/idleDuration`` and calls
/// ``InferenceService/unloadModel(reason:)`` with ``UnloadReason/idleTimeout``
/// when the model has been idle for longer than the configured threshold.
///
/// Any generation activity resets the idle clock, so a busy model is never
/// evicted mid-turn.
///
/// ```swift
/// // Unload after 5 minutes of silence (Ollama-style keep-alive):
/// inferenceService.keepAlivePolicy = KeepAlivePolicy(idleTimeout: 5 * 60)
///
/// // Disable auto-unload (the default):
/// inferenceService.keepAlivePolicy = .never
/// ```
public struct KeepAlivePolicy: Sendable, Equatable {

    /// How long the model may be idle before being automatically unloaded.
    ///
    /// `nil` disables auto-unload. A value of `0` would unload the model
    /// immediately after every generation; prefer a small positive value
    /// (≥ 1 second) in practice.
    public var idleTimeout: TimeInterval?

    /// Whether the resident model may be *preemptively* evicted when the OS
    /// raises an elevated — but not yet critical — memory-pressure warning.
    ///
    /// Opt-in (default `false`). The default reactive behaviour only evicts on a
    /// **critical** pressure level. Setting this to `true` lets the engine free
    /// the model one step earlier, at `.warning`, so the app is less likely to
    /// be pushed to `.critical` (or terminated) in the first place — at the cost
    /// of an extra reload if the warning was transient.
    ///
    /// A `.warning` eviction is *advisory and conservative*: it fires only when
    /// the model is **idle past ``memoryWarningGrace``** and is **not** busy
    /// generating. A `.warning` raised mid-turn never interrupts generation.
    public var evictOnMemoryWarning: Bool

    /// How long the model must have been idle before a `.warning`-level pressure
    /// event is allowed to preemptively evict it.
    ///
    /// This short grace window prevents a `.warning` that lands moments after a
    /// turn completes from tearing down a model the user is actively using.
    /// Only consulted when ``evictOnMemoryWarning`` is `true`. Defaults to 10s.
    public var memoryWarningGrace: TimeInterval

    /// The default policy: no automatic unloading.
    public static let never = KeepAlivePolicy(idleTimeout: nil)

    /// Creates a policy with the given idle timeout.
    ///
    /// - Parameters:
    ///   - idleTimeout: Seconds of idle time after which the model is
    ///     automatically unloaded. Pass `nil` to disable auto-unload.
    ///   - evictOnMemoryWarning: When `true`, an idle model may also be evicted
    ///     on a `.warning`-level memory-pressure event (not just `.critical`).
    ///     Defaults to `false`.
    ///   - memoryWarningGrace: Minimum idle duration before a `.warning` may
    ///     preemptively evict. Defaults to 10 seconds. Ignored unless
    ///     `evictOnMemoryWarning` is `true`.
    public init(
        idleTimeout: TimeInterval?,
        evictOnMemoryWarning: Bool = false,
        memoryWarningGrace: TimeInterval = 10
    ) {
        self.idleTimeout = idleTimeout
        self.evictOnMemoryWarning = evictOnMemoryWarning
        self.memoryWarningGrace = memoryWarningGrace
    }
}
