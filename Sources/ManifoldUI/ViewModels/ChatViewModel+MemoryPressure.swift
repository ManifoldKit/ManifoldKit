import Foundation
import ManifoldRuntime
import ManifoldInference
// MemoryPressureHandler is @_spi(BackendInternals) — published backend seam (#1749).
@_spi(BackendInternals) import ManifoldHardware

// MARK: - ChatViewModel + Memory Pressure

extension ChatViewModel {

    public func startMemoryMonitoring() {
        memoryPressure.startMonitoring()
    }

    public func stopMemoryMonitoring() {
        memoryPressure.stopMonitoring()
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
