import Foundation
import ManifoldInference

#if canImport(AppIntents)
import AppIntents
#endif

#if canImport(AppIntents)

// MARK: - ProgressReportingAppIntent

/// Marker conformance for AppIntents that emit interim progress events while
/// ``AppIntent/perform()`` runs.
///
/// Adopters keep their existing `perform()` implementation and, at sensible
/// checkpoints, pull the task-local
/// ``IntentProgressReporter/current`` reporter and call
/// ``IntentProgressReporter/report(message:fraction:)``. Each call is forwarded
/// to the surrounding ``AppIntentToolExecutor/executeStreaming(arguments:)``
/// stream as a ``ToolExecutionEvent/progress(message:fraction:)`` chunk.
///
/// ```swift
/// struct DownloadModelIntent: ProgressReportingAppIntent, Decodable {
///     static let title: LocalizedStringResource = "Download Model"
///     static var supportsProgressReporting: Bool { true }
///
///     @Parameter(title: "Model ID")
///     var modelId: String
///
///     func perform() async throws -> some IntentResult {
///         let reporter = IntentProgressReporter.current
///         for step in 1...4 {
///             try await doStep(step)
///             await reporter?.report(
///                 message: "Step \(step) of 4",
///                 fraction: Double(step) / 4.0
///             )
///         }
///         return .result()
///     }
/// }
/// ```
///
/// Non-streaming intents simply do not adopt this protocol; the default
/// ``ToolExecutor/executeStreaming(arguments:)`` wrapper still yields a single
/// `.completed` event so callers can use the streaming API uniformly.
@available(iOS 26, macOS 26, *)
public protocol ProgressReportingAppIntent: AppIntent {

    /// Compile-time flag that the executor reads to decide whether to install a
    /// task-local ``IntentProgressReporter`` before invoking
    /// ``AppIntent/perform()``.
    ///
    /// Defaults to `true` via a protocol extension — adopters generally do not
    /// need to set this explicitly. Override to `false` only when temporarily
    /// disabling progress reporting on a type that still needs to satisfy the
    /// protocol for some other reason.
    static var supportsProgressReporting: Bool { get }
}

@available(iOS 26, macOS 26, *)
extension ProgressReportingAppIntent {
    public static var supportsProgressReporting: Bool { true }
}

// MARK: - IntentProgressReporter

/// Actor-isolated drain that ``ProgressReportingAppIntent/perform()`` pulls
/// from the task-local ``current`` slot and forwards progress events into.
///
/// `AppIntentToolExecutor` installs an instance into the task-local before
/// invoking `perform()`, attaches the reporter's
/// `AsyncStream<ToolExecutionEvent>` to its outer
/// `AsyncThrowingStream<ToolExecutionEvent, Error>`, and finishes the reporter
/// once `perform()` returns. Intents see a single static
/// ``current`` accessor — they don't need to thread the reporter through their
/// method signatures.
///
/// The actor isolation is deliberate: `perform()` may suspend on background
/// executors (downloads, file I/O), and an `actor` makes
/// ``report(message:fraction:)`` safe to call from any task without an
/// `@unchecked Sendable` hack.
@available(iOS 26, macOS 26, *)
public actor IntentProgressReporter {

    /// Task-local handle the running intent pulls from inside `perform()`.
    ///
    /// `nil` outside of a streaming-aware dispatch (e.g. when the intent runs
    /// under the legacy single-shot ``ToolExecutor/execute(arguments:)`` path,
    /// or directly outside ManifoldKit). Intents that opt into streaming
    /// should treat the optional as soft — calling `report(...)` on the
    /// optional is a no-op when nil, which preserves correctness under both
    /// streaming and non-streaming dispatch paths.
    @TaskLocal public static var current: IntentProgressReporter?

    private let continuation: AsyncStream<ToolExecutionEvent>.Continuation
    private let stream: AsyncStream<ToolExecutionEvent>

    /// Creates a reporter and its backing stream.
    ///
    /// The executor owns both ends: the reporter is published via the
    /// task-local for the intent to push into, while ``events`` is drained by
    /// the executor and forwarded onto the outer caller-visible stream.
    public init() {
        var sink: AsyncStream<ToolExecutionEvent>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            sink = continuation
        }
        self.continuation = sink
    }

    /// Emits a progress event into the surrounding executor stream.
    ///
    /// - Parameters:
    ///   - message: Human-readable status string. Should be safe to render
    ///     directly in UI.
    ///   - fraction: Optional 0.0...1.0 completion fraction. Pass `nil` when
    ///     the total is unknown (open-ended fetch, single-step ping).
    public func report(message: String, fraction: Double? = nil) {
        continuation.yield(.progress(message: message, fraction: fraction))
    }

    /// The progress event sequence the executor drains.
    ///
    /// Marked `nonisolated` because `AsyncStream` itself is `Sendable` and
    /// each yield is funneled through the actor-isolated ``report(message:fraction:)``;
    /// the consumer side has no shared mutable state.
    public nonisolated var events: AsyncStream<ToolExecutionEvent> { stream }

    /// Closes the backing stream so the executor's drain loop terminates.
    ///
    /// Called by the executor after `perform()` returns (or throws); intents
    /// must not call this themselves.
    public func finish() {
        continuation.finish()
    }
}

#endif // canImport(AppIntents)
