import Foundation

// MARK: - ModelLoadStatus

/// A headless, multi-observer view of a model load's lifecycle.
///
/// `ModelLoadCoordinator`'s original output was a set of single-owner
/// `@MainActor` callback seams wired into one `ChatViewModel`. That shape cannot
/// serve two consumers at once — a future headless `ModelSelection` façade and the
/// existing chat view model both want to watch the same load. `ModelLoadStatus`
/// is the shared, fan-out signal: every observer subscribes to its own
/// `AsyncStream` (see ``ModelLoadCoordinator/statusUpdates()``) and sees the same
/// transitions without clobbering anyone else's callbacks.
///
/// The richer chat-only side effects (prompt-template selection, token-cache
/// invalidation) stay on the callback seams; only the progress / phase / error
/// path is mirrored here, because that is the part multiple observers need.
public enum ModelLoadStatus: Sendable, Equatable {
    /// No load is in flight (initial state, and the terminal state after a load
    /// completes, is unloaded, or is invalidated).
    case idle
    /// A load is in flight. `progress` is `nil` until the backend reports a
    /// fractional value (some backends never do).
    case loading(progress: Double?)
    /// The most recent load committed successfully.
    case loaded
    /// The most recent load failed. `reason` is a user-presentable message.
    case failed(reason: String)
}
