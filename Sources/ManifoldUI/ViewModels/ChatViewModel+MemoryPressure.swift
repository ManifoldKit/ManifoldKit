import Foundation
import ManifoldRuntime
import ManifoldInference
// MemoryPressureHandler is @_spi(BackendInternals) — published backend seam (#1749).
@_spi(BackendInternals) import ManifoldHardware

// MARK: - ChatViewModel + Memory Pressure

extension ChatViewModel {

    public func startMemoryMonitoring() {
        memoryPressure.startMonitoring()
        guard !isObservingMemoryPressureChanges else { return }
        isObservingMemoryPressureChanges = true
        observeMemoryPressureChanges()
    }

    public func stopMemoryMonitoring() {
        memoryPressure.stopMonitoring()
        isObservingMemoryPressureChanges = false
    }

    /// Bridges real OS memory-pressure events into ``handleMemoryPressure()``.
    ///
    /// `MemoryPressureHandler.pressureLevel` is `@Observable` but nothing was ever
    /// watching it — the mitigation path (stop generation, unload model, invalidate
    /// caches, surface an error) was reachable only from tests calling
    /// `handleMemoryPressure()` directly. This mirrors the self-reinstalling
    /// `withObservationTracking` pattern already used by
    /// `InferenceService.ModelLoadReadinessObserver.emitAndTrack()`
    /// (`Sources/ManifoldInference/Services/InferenceService.swift`): `onChange`
    /// fires once per registration, so each firing re-installs itself before acting,
    /// which keeps every subsequent OS-driven level change live. `stopMemoryMonitoring()`
    /// clears `isObservingMemoryPressureChanges`, which stops the chain from re-arming.
    private func observeMemoryPressureChanges() {
        withObservationTracking {
            _ = memoryPressure.pressureLevel
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isObservingMemoryPressureChanges else { return }
                self.handleMemoryPressure()
                self.observeMemoryPressureChanges()
            }
        }
    }

    public func handleMemoryPressure() {
        let level = memoryPressure.pressureLevel
        let responder = MemoryPressureResponder()
        let actions = responder.actions(for: level, lastLevel: lastPressureLevel)
        guard !actions.isEmpty else { return }
        lastPressureLevel = level

        // Notify InferenceService subscribers about the new OS level. Do this
        // before acting on the level so subscribers see the level change before
        // any resulting willUnload/didUnload events.
        inferenceService.notifyPressureLevel(level)

        for action in actions {
            switch action {
            case .stopGeneration:
                stopGeneration()
            case .unloadModel:
                // Use the pressure-specific overload so subscribers receive the
                // correct UnloadReason instead of the generic .userRequested.
                inferenceService.unloadModel(reason: .criticalMemoryPressure)
                loadCoordinator.invalidatePendingLoadIntent(resetActivityPhase: true)
                invalidateTokenCaches()
            case .setError(let error):
                activeError = error
            case .clearMemoryPressureError:
                if activeError?.kind == .memoryPressure {
                    activeError = nil
                }
            }
        }
    }
}
