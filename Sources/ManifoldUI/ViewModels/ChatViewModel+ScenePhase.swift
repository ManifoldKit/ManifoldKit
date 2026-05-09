import SwiftUI
import ManifoldRuntime

// MARK: - ChatViewModel + Scene Phase

extension ChatViewModel {

    /// Responds to an app scene-phase transition.
    ///
    /// When the app moves to `.background`, any active generation is cancelled
    /// cleanly so no zombie tasks outlive the foreground session. When the app
    /// returns to `.foreground`, no automatic action is taken — the VM is already
    /// stable and the user can continue chatting normally.
    ///
    /// Call this from your root view's `onChange(of: scenePhase)` modifier:
    ///
    /// ```swift
    /// @Environment(\.scenePhase) private var scenePhase
    ///
    /// .onChange(of: scenePhase) { _, newPhase in
    ///     chatViewModel.handleScenePhaseChange(to: newPhase)
    /// }
    /// ```
    public func handleScenePhaseChange(to phase: ScenePhase) {
        switch phase {
        case .background:
            // Cancel mid-stream generation so no tasks keep running in the background.
            if isGenerating {
                stopGeneration()
            }
        case .active, .inactive:
            // No action on foreground return — the VM is already stable.
            break
        @unknown default:
            break
        }
    }
}
