#if canImport(BackgroundTasks)
import BackgroundTasks
import Foundation

/// Bridges ``ConversationRuntime`` into a `BGContinuedProcessingTask` expiration handler.
///
/// `BGContinuedProcessingTask.expirationHandler` is synchronous; ``ConversationRuntime/cancelAllTurns()``
/// is async. This type fires a detached `Task` to close the gap.
///
/// ## Usage
///
/// ```swift
/// // In your app's BGTaskScheduler submission:
/// let bridge = ConversationRuntimeBackgroundBridge(runtime: conversationRuntime)
/// task.expirationHandler = { bridge.handleExpiration() }
/// BGTaskScheduler.shared.submit(task, toQueue: nil)
/// ```
public struct ConversationRuntimeBackgroundBridge: Sendable {
    private let runtime: ConversationRuntime

    public init(runtime: ConversationRuntime) {
        self.runtime = runtime
    }

    /// Call this from `BGContinuedProcessingTask.expirationHandler`.
    ///
    /// Fires a detached task that calls ``ConversationRuntime/cancelAllTurns()``.
    /// Returns immediately; cancellation completes asynchronously.
    ///
    /// `Task.detached` is intentional here: `expirationHandler` fires on an
    /// arbitrary background thread with no actor context. A plain `Task {}` would
    /// inherit whichever executor happens to be current on that thread, which is
    /// undefined. `Task.detached` gives us a clean, unconfined context from which
    /// we hop into `ConversationRuntime`'s own concurrency domain. The runtime is
    /// captured strongly because expiration MUST complete — a `[weak runtime]`
    /// capture could allow the runtime to be released before cancellation finishes,
    /// silently dropping in-flight turns.
    public func handleExpiration() {
        Task.detached { [runtime] in
            await runtime.cancelAllTurns()
        }
    }

    /// Returns whether background GPU acceleration is available on this device.
    ///
    /// Background GPU requires the `com.apple.developer.background-tasks.continued-processing.gpu`
    /// entitlement and is supported on iPad only — not iPhone. Check this before
    /// submitting a `BGContinuedProcessingTask` that relies on ``MLXBackend``.
    ///
    /// On macOS, GPU access is not restricted when the app is backgrounded.
    #if os(iOS)
    @available(iOS 26, *)
    public static var backgroundGPUAvailable: Bool {
        BGTaskScheduler.supportedResources.contains(.gpu)
    }
    #endif
}
#endif
