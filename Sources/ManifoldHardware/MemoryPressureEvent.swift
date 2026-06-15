import Foundation

// MARK: - UnloadReason

/// The reason a model was unloaded from memory.
public enum UnloadReason: Sendable, Equatable {
    /// The OS raised a critical memory-pressure notification.
    case criticalMemoryPressure
    /// The host application or user explicitly requested unloading.
    case userRequested
    /// The model was evicted while the app was in the background.
    case backgroundEviction
    /// The model exceeded the configured idle keep-alive TTL and was automatically unloaded.
    case idleTimeout
}

// MARK: - MemoryPressureEvent

/// An event emitted by ``InferenceService/memoryPressureEvents()`` that describes
/// model lifecycle or OS memory-pressure transitions.
///
/// Consumers subscribe to this stream to drive UI (e.g., show a "model unloaded"
/// banner), log telemetry, or trigger reload logic — without polling
/// ``InferenceService/isModelLoaded``.
///
/// ```swift
/// for await event in inferenceService.memoryPressureEvents() {
///     switch event {
///     case .willUnload(let id, let reason):
///         print("Model \(id) will unload: \(reason)")
///     case .didUnload(let id, _):
///         showReloadPrompt(for: id)
///     case .didReload(let id):
///         hideReloadPrompt(for: id)
///     case .levelChanged(let level):
///         updateMemoryIndicator(level)
///     }
/// }
/// ```
public enum MemoryPressureEvent: Sendable, Equatable {
    /// The OS memory-pressure level changed.
    case levelChanged(MemoryPressureLevel)
    /// A model is about to be unloaded. `modelID` matches the ``ModelInfo/id`` passed
    /// to the originating ``InferenceService/loadModel(from:plan:)`` call, or a
    /// synthetic sentinel UUID when loading was done through a cloud backend path that
    /// carries no `ModelInfo`.
    case willUnload(modelID: UUID, reason: UnloadReason)
    /// A model was unloaded. Follows every ``willUnload`` with the same `modelID`.
    case didUnload(modelID: UUID, reason: UnloadReason)
    /// A model was successfully (re-)loaded. `modelID` matches the ``ModelInfo/id``
    /// of the newly loaded model.
    case didReload(modelID: UUID)
}
