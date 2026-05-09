import Foundation
import ManifoldRuntime
import ManifoldInference

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

        for action in actions {
            switch action {
            case .stopGeneration:
                stopGeneration()
            case .unloadModel:
                unloadModel()
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
