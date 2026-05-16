import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ChatViewModel + GenerationCoordinator wiring

extension ChatViewModel {

    /// Wires ``ChatGenerationCoordinator`` closures to this view model.
    ///
    /// Called once at the end of `init` after `installSessionManagerClosures()`.
    /// The closures capture `self` weakly so the coordinator does not extend the
    /// view model's lifetime.
    func installGenerationCoordinatorClosures() {
        let coord = generationCoordinator

        // MARK: State write-backs

        coord.onTransitionPhase = { [weak self] phase in
            guard let self else { return false }
            // Write directly to the observable property — the machine inside
            // the coordinator has already validated the transition.
            activityPhase = phase
            return true
        }

        coord.onSetLastTurnState = { [weak self] state in
            self?.lastTurnState = state
        }

        coord.onSetBackgroundTaskError = { [weak self] error in
            self?.backgroundTaskError = error
        }

        coord.onSetMessageIDsWithStreamingThinking = { [weak self] ids in
            self?.messageIDsWithStreamingThinking = ids
        }

        // MARK: Read-backs

        coord.currentActiveSessionID = { [weak self] in
            self?.activeSessionID
        }

        coord.currentActiveSession = { [weak self] in
            self?.activeSession
        }

        coord.currentMessages = { [weak self] in
            self?.messages ?? []
        }

        coord.currentPostGenerationTasks = { [weak self] in
            self?.postGenerationTasks ?? []
        }

        // MARK: Message mutations

        coord.mutateMessage = { [weak self] id, body in
            self?.mutateMessage(id: id, body) ?? false
        }

        coord.appendMessage = { [weak self] record in
            self?.messages.append(record)
        }

        coord.removeMessages = { [weak self] predicate in
            self?.messages.removeAll(where: predicate)
        }

        // MARK: Side effects

        coord.updateContextEstimate = { [weak self] in
            self?.updateContextEstimate()
        }

        coord.surfaceError = { [weak self] error, kind in
            self?.surfaceError(error, kind: kind)
        }

        coord.setErrorMessage = { [weak self] message in
            self?.errorMessage = message
        }

        coord.setShowUpgradeHint = { [weak self] show in
            guard let self, show else { return }
            guard ManifoldConfiguration.shared.features.showUpgradeHint else { return }
            guard !showUpgradeHint else { return }
            guard activeBackendName == BackendName.foundation.rawValue else { return }
            guard messages.filter({ $0.role == .assistant }).count == 1 else { return }
            showUpgradeHint = true
            onUpgradeHintTriggered?()
        }

        coord.onSessionBranched = { [weak self] newSessionID in
            await self?.onSessionBranched?(newSessionID)
        }
    }
}
