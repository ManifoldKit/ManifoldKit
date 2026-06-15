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

    /// The default policy: no automatic unloading.
    public static let never = KeepAlivePolicy(idleTimeout: nil)

    /// Creates a policy with the given idle timeout.
    ///
    /// - Parameter idleTimeout: Seconds of idle time after which the model
    ///   is automatically unloaded. Pass `nil` to disable auto-unload.
    public init(idleTimeout: TimeInterval?) {
        self.idleTimeout = idleTimeout
    }
}
