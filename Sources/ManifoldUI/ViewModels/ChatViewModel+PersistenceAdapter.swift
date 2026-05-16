import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ChatViewModel + PersistenceAdapter wiring

extension ChatViewModel {

    /// Wires ``ChatPersistenceAdapter`` closures to this view model's collaborators.
    ///
    /// Called once at the end of `init` after all stored properties are
    /// initialized. The closure captures `self` weakly so the adapter does not
    /// extend the view model's lifetime.
    ///
    /// When the adapter accepts a persistence store, the runtime is rebuilt
    /// against it — but only when `ChatViewModel` owns the default in-memory
    /// runtime (i.e. the host did not pass `conversationRuntime:` at
    /// construction). Hosts that pass their own runtime are unaffected.
    func installPersistenceAdapterClosures() {
        let adapter = persistenceAdapter

        adapter.onPersistenceConfigured = { [weak self] store in
            guard let self, self.generationCoordinator.ownsDefaultRuntime else { return }
            let newRuntime = ConversationRuntime(
                messageStore: store,
                sessionStore: store,
                inferenceService: self.inferenceService
            )
            self.generationCoordinator.replaceRuntime(newRuntime)
        }
    }
}
