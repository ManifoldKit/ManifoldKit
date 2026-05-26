import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ChatViewModel + Model Loading (facade)

// Two-tier load coordination:
// - ChatViewModel (this layer) owns UI task lifecycle via `ModelLoadCoordinator` —
//   superseded async tasks are cancelled before they reach InferenceService.
// - InferenceService owns backend state correctness via monotonic LoadRequestToken —
//   any stale completion that does reach the service layer is suppressed there.
// Together they provide defense-in-depth: this layer avoids redundant load attempts;
// InferenceService provides the hard correctness guarantee.

extension ChatViewModel {

    /// Coordinates loading for the currently selected model/endpoint.
    ///
    /// Newest selection always wins; any older in-flight coordinated load intent is
    /// cancelled and invalidated.
    public func dispatchSelectedLoad() {
        guard let intent = currentLoadIntent else { return }
        loadCoordinator.dispatchLoad(intent)
    }

    /// Manually unloads the active backend and invalidates any pending coordinated load.
    public func unloadModel() {
        loadCoordinator.invalidatePendingLoadIntent(resetActivityPhase: true)
        inferenceService.unloadModel()
        // Token counts are keyed by message UUID, which is reused across sessions.
        // Dropping them here prevents counts computed with the previous model's
        // tokenizer from being returned after a subsequent model swap.
        invalidateTokenCaches()
    }

    /// Loads the currently selected local model into the inference backend.
    ///
    /// Does nothing if a load is already in progress. Sets `isLoading` for the duration
    /// and writes to `errorMessage` on failure. Auto-detects the GGUF prompt template
    /// from model metadata before loading.
    ///
    /// - Note: Prefer `dispatchSelectedLoad()` for UI-driven loads — it coordinates
    ///   intent and cancels superseded requests.
    public func loadSelectedModel() async {
        guard !isLoading else { return }

        guard let model = selectedModel else {
            activeError = ChatError(kind: .configuration, message: "No model selected.", recovery: .selectModel)
            return
        }

        await loadCoordinator.loadLocalModel(model, generation: nil)
    }

    /// Loads the currently selected cloud/LAN endpoint into the inference backend.
    ///
    /// Does nothing if a load is already in progress. Hosts that drive selection
    /// through `selectedEndpoint` can call this directly; SwiftUI pickers that
    /// react to selection changes should prefer ``dispatchSelectedLoad()``.
    public func loadSelectedEndpoint() async {
        guard !isLoading else { return }

        guard let endpoint = selectedEndpoint else {
            activeError = ChatError(kind: .configuration, message: "No endpoint selected.", recovery: .selectModel)
            return
        }

        await loadCoordinator.loadCloudEndpointInternal(endpoint, generation: nil)
    }

    /// Loads a cloud API endpoint for the active session.
    ///
    /// - Note: Prefer `dispatchSelectedLoad()` for UI-driven loads — it coordinates
    ///   intent and cancels superseded requests.
    public func loadCloudEndpoint(_ endpoint: APIEndpointRecord) async {
        await loadCoordinator.loadCloudEndpointInternal(endpoint, generation: nil)
    }

    // MARK: - Private helpers

    private var currentLoadIntent: LoadIntent? {
        if let endpoint = selectedEndpoint {
            return .cloudEndpoint(endpoint)
        }
        if let model = selectedModel {
            return .localModel(model)
        }
        return nil
    }
}
