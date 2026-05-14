import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ChatViewModel + SessionManager wiring

extension ChatViewModel {

    /// Wires ``ChatSessionManager`` closures to this view model's collaborators.
    ///
    /// Called once at the end of `init` after all stored properties are
    /// initialized. The closures capture `self` weakly so the session manager
    /// does not extend the view model's lifetime. Every closure re-checks
    /// `guard let self` before touching state.
    ///
    /// This is the only place where `ChatSessionManager` learns about
    /// `InferenceService`, `ConversationRuntime`, and other concrete types —
    /// the manager itself stays decoupled and testable in isolation.
    func installSessionManagerClosures() {
        let mgr = sessionManager

        mgr.discardRequests = { [weak self] sessionID in
            guard let self else { return }
            await self.inferenceService.discardRequests(notMatching: sessionID)
        }

        mgr.resetConversation = { [weak self] in
            self?.inferenceService.resetConversation()
        }

        mgr.secureWipe = { [weak self] in
            self?.inferenceService.secureWipe()
        }

        mgr.applyPromptTemplate = { [weak self] template in
            self?.inferenceService.selectedPromptTemplate = template
        }

        mgr.cancelActiveStreamHandle = { [weak self] in
            guard let self else { return }
            if let handle = self.activeConversationStreamHandle {
                await self.conversationRuntime.cancel(handle)
                self.activeConversationStreamHandle = nil
            }
        }

        mgr.resetToolApprovals = { [weak self] in
            self?.toolApprovalGate?.resetForNewSession()
        }

        mgr.cancelBackgroundTask = { [weak self] in
            guard let self else { return }
            self.backgroundTask?.cancel()
            self.backgroundTask = nil
            self.backgroundTaskError = nil
        }

        mgr.refreshAvailableEndpoints = { [weak self] in
            await self?.refreshAvailableEndpointsFromStore()
        }

        mgr.resolveModel = { [weak self] modelID in
            self?.availableModels.first(where: { $0.id == modelID })
        }

        mgr.resolveEndpoint = { [weak self] endpointID in
            self?.availableEndpoints.first(where: { $0.id == endpointID })
        }

        mgr.applyModelSelection = { [weak self] model in
            self?.selectedModel = model
        }

        mgr.applyEndpointSelection = { [weak self] endpoint in
            self?.selectedEndpoint = endpoint
        }
    }
}
