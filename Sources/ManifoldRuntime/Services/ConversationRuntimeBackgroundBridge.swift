#if canImport(BackgroundTasks)
import BackgroundTasks
import Foundation

/// Recommended task identifier strings for `BGTaskScheduler`.
///
/// `BGTaskScheduler` requires task identifiers to be declared in the host
/// app's `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`. These
/// constants are the recommended values so multiple ManifoldKit-based apps
/// share a stable convention; callers are free to use their own strings.
///
/// `continueGeneration` is the identifier ``ConversationRuntimeBackgroundBridge``
/// documents for its `BGContinuedProcessingTask` recipe (see the
/// <doc:BackgroundTaskSupport> article). The remaining constants are reserved
/// conventions for other background-task shapes a host app may wire up itself
/// (post-generation extraction, index maintenance, chat archiving) — ManifoldKit
/// does not schedule that work; they exist so multiple ManifoldKit-based apps
/// converge on the same `Info.plist` strings.
///
/// Example `Info.plist` entry:
///
/// ```xml
/// <key>BGTaskSchedulerPermittedIdentifiers</key>
/// <array>
///     <string>com.manifoldkit.background.post-generation</string>
///     <string>com.manifoldkit.background.indexing</string>
///     <string>com.manifoldkit.background.archive</string>
///     <string>com.manifoldkit.runtime.continueGeneration</string>
/// </array>
/// ```
public enum ManifoldBackgroundTaskIdentifiers {
    /// Identifier for post-generation extraction / summarisation work.
    public static let postGeneration = "com.manifoldkit.background.post-generation"
    /// Identifier for vector / search index maintenance.
    public static let indexing = "com.manifoldkit.background.indexing"
    /// Identifier for chat archive and export work.
    public static let archive = "com.manifoldkit.background.archive"
    /// Task identifier for continuing an in-progress generation turn after the app backgrounds.
    ///
    /// Register this in your app's `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`.
    public static let continueGeneration = "com.manifoldkit.runtime.continueGeneration"
}

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
