import Foundation
import ManifoldInference

// MARK: - MemoryPressureResponder

/// Pure decision tree that maps a memory-pressure level transition to a list of
/// actions for `ChatViewModel` to apply.
///
/// Extracted from `ChatViewModel+MemoryPressure.swift` (phase 2 of #329). The
/// responder owns no mutable state; the view model reads the current/previous
/// pressure levels, asks for actions, and applies them.
struct MemoryPressureResponder {

    enum Action {
        case setError(ChatError)
        case clearMemoryPressureError
        case stopGeneration
        case unloadModel
    }

    func actions(for level: MemoryPressureLevel, lastLevel: MemoryPressureLevel) -> [Action] {
        guard level != lastLevel else { return [] }

        switch level {
        case .critical:
            return [
                .stopGeneration,
                .unloadModel,
                .setError(
                    ChatError(
                        kind: .memoryPressure,
                        message: "Memory pressure is critical. The model was unloaded to prevent the app from being terminated.",
                        recovery: .dismissOnly
                    )
                )
            ]
        case .warning:
            return [
                .setError(
                    ChatError(
                        kind: .memoryPressure,
                        message: "Memory pressure is elevated. Consider closing other apps.",
                        recovery: .dismissOnly
                    )
                )
            ]
        case .nominal:
            return [.clearMemoryPressureError]
        }
    }
}
