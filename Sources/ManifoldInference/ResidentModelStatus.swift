import Foundation

/// A point-in-time snapshot of the currently resident model's identity and
/// runtime characteristics.
///
/// Obtained via ``InferenceService/residentModelStatus``. Returns `nil` when
/// no model is loaded. Useful for dashboards, telemetry, and idle-eviction
/// policies that need to know which model is loaded, how long it has been idle,
/// and how much memory it is estimated to occupy.
///
/// ```swift
/// if let status = inferenceService.residentModelStatus {
///     print("Model: \(status.modelID) via \(status.backend)")
///     print("Idle for \(status.idleDuration.formatted()) seconds")
/// }
/// ```
public struct ResidentModelStatus: Sendable {

    /// The human-readable model identifier (e.g. `ModelInfo.name`).
    public let modelID: String

    /// The backend engine label (e.g. `"Mock"`, `"llama"`, `"ollama"`).
    public let backend: String

    /// Best-effort selection-time footprint estimate in bytes.
    ///
    /// Sourced from `ModelLoadPlan.outcome.totalEstimatedBytes` for local
    /// (on-disk) loads. `nil` for cloud / system-managed endpoints where no
    /// local memory estimate is computed.
    public let estimatedFootprintBytes: UInt64?

    /// The moment the model transitioned to `isModelLoaded == true`.
    public let loadedAt: Date

    /// The timestamp of the most recent queue activity: enqueue, dequeue-to-active,
    /// or request completion.
    public let lastActivityAt: Date

    /// Seconds elapsed since the last queue activity.
    ///
    /// Computed on access so the value reflects wall time without requiring a
    /// periodic refresh of the snapshot itself.
    public var idleDuration: TimeInterval { Date().timeIntervalSince(lastActivityAt) }
}
