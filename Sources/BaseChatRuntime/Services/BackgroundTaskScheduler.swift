import Foundation

// MARK: - Memory Budget

/// Memory ceiling enforced while a background task runs.
///
/// The scheduler samples the process's resident memory periodically and
/// cancels the in-flight task when the footprint exceeds ``maxBytes``. This
/// protects long-running extraction or indexing work from blowing through the
/// jetsam budget that the OS assigns to background-mode apps on iOS.
///
/// The default of 50 MB matches the headroom that `BGProcessingTask` callers
/// can realistically count on across the supported device matrix without
/// being killed; raise it only when the host app has measured a higher
/// safe ceiling on its target hardware.
public struct MemoryBudget: Sendable, Equatable {

    /// Byte ceiling for the running task. Sampled periodically; tasks that
    /// exceed this value are cancelled.
    public let maxBytes: UInt64

    /// How often the scheduler samples memory usage while the task runs.
    public let sampleInterval: Duration

    public init(maxBytes: UInt64, sampleInterval: Duration = .milliseconds(500)) {
        self.maxBytes = maxBytes
        self.sampleInterval = sampleInterval
    }

    /// 50 MB — the default ceiling for `BGProcessingTask` work.
    public static let `default` = MemoryBudget(maxBytes: 50 * 1024 * 1024)
}

// MARK: - Recommended Identifiers

/// Recommended task identifier strings for `BGTaskScheduler`.
///
/// `BGTaskScheduler` requires task identifiers to be declared in the host
/// app's `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`. These
/// constants are the recommended values so multiple BaseChatKit-based apps
/// share a stable convention; callers are free to use their own strings.
///
/// Example `Info.plist` entry:
///
/// ```xml
/// <key>BGTaskSchedulerPermittedIdentifiers</key>
/// <array>
///     <string>com.basechatkit.background.post-generation</string>
///     <string>com.basechatkit.background.indexing</string>
///     <string>com.basechatkit.background.archive</string>
/// </array>
/// ```
public enum BaseChatBackgroundTaskIdentifiers {
    /// Identifier for post-generation extraction / summarisation work.
    public static let postGeneration = "com.basechatkit.background.post-generation"
    /// Identifier for vector / search index maintenance.
    public static let indexing = "com.basechatkit.background.indexing"
    /// Identifier for chat archive and export work.
    public static let archive = "com.basechatkit.background.archive"
}

// MARK: - Scheduler Protocol

/// Schedules in-process background work with a memory-budget watchdog.
///
/// The default implementation is ``DefaultBackgroundTaskScheduler``. It runs
/// the closure on a detached `Task` on both iOS and macOS, and on iOS also
/// submits a best-effort `BGProcessingTaskRequest` so a host app that wires
/// up its own `BGTaskScheduler.register(...)` launch handler can pick up
/// queued work after the process is relaunched. The default implementation
/// itself does **not** install a launch handler and does **not** persist
/// `work` across launches — treat the protocol as an in-process scheduler
/// with budget enforcement, not as a guaranteed background-execution bridge.
///
/// Both paths enforce the configured ``MemoryBudget`` — work whose process
/// footprint breaches the ceiling has its `Task` cancelled, and the closure
/// observes the cancellation through the standard `Task.isCancelled` /
/// `try Task.checkCancellation()` channel. The host can re-schedule from
/// there.
///
/// `identifier` is a free-form string. On iOS it must match an entry in
/// `BGTaskSchedulerPermittedIdentifiers` (see ``BaseChatBackgroundTaskIdentifiers``)
/// for the best-effort BG request submission to succeed; on macOS it is
/// used purely as a cancellation key.
public protocol BackgroundTaskScheduler: Sendable {

    /// Schedules `work` to run in the background, enforcing `budget`.
    ///
    /// Calling `schedule` twice with the same `identifier` cancels the
    /// previously-scheduled run before starting the new one — `schedule`
    /// is therefore safe to use as a "replace if newer" primitive.
    ///
    /// - Parameters:
    ///   - identifier: Stable identifier for this work. Must be registered in
    ///     `Info.plist` on iOS.
    ///   - budget: Memory ceiling enforced while the closure runs. Defaults
    ///     to ``MemoryBudget/default`` (50 MB).
    ///   - work: The async work to execute. The task is cancelled when the
    ///     memory budget is exceeded or ``cancel(identifier:)`` is called.
    func schedule(
        identifier: String,
        budget: MemoryBudget,
        work: @Sendable @escaping () async throws -> Void
    ) async

    /// Cancels the work scheduled under `identifier`, if any.
    ///
    /// No-op if the identifier has no in-flight or pending work.
    func cancel(identifier: String)
}

// MARK: - Default Argument Convenience

extension BackgroundTaskScheduler {

    /// Convenience: schedules with ``MemoryBudget/default``.
    public func schedule(
        identifier: String,
        work: @Sendable @escaping () async throws -> Void
    ) async {
        await schedule(identifier: identifier, budget: .default, work: work)
    }
}
