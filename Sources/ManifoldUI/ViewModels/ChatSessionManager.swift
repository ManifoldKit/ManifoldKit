import Foundation
import Observation
import ManifoldRuntime
import ManifoldInference

/// Coordinates session-switching transitions in the chat UI.
///
/// `ChatSessionManager` owns the teardown-and-setup choreography that runs
/// whenever the user picks a different session: cancelling in-flight
/// inference, tearing down the runtime stream handle, resetting per-session
/// tool-approval state, and resolving the persisted model/endpoint selection
/// from the new session's stored IDs.
///
/// It is intentionally decoupled from every collaborator via closure
/// injection, making it testable without constructing a full
/// `ChatViewModel`. `ChatViewModel` owns one instance and delegates the
/// orchestration methods; the `+SessionManagement` extension remains the
/// public surface that callers see.
///
/// `SessionController` owns the complementary lower layer: session-record
/// activation, settings I/O, and message loading. `ChatSessionManager`
/// sits one level above, coordinating the inference-side teardown before
/// `SessionController.activateSession(_:)` runs.
@Observable
@MainActor
final class ChatSessionManager {

    // MARK: - State

    /// `true` while a session switch is in progress.
    ///
    /// `ModelLoadCoordinator` reads this flag to suppress stale model-load
    /// transitions that arrive mid-switch — a new session select must not be
    /// shadowed by the dying session's load progress.
    var isRestoringSession: Bool = false

    // MARK: - Teardown collaborators (closure-injected)
    //
    // Each closure captures a specific piece of `ChatViewModel` state or an
    // external service without coupling this type to any concrete class.
    // Closures are set once during `ChatViewModel.init` and never replaced.

    /// Cancels in-flight inference requests that do not belong to `sessionID`.
    var discardRequests: (@MainActor (UUID) async -> Void)?

    /// Resets the active backend conversation history and zeroes the KV cache.
    var resetConversation: (@MainActor () -> Void)?

    /// Zeroes the model's KV cache via a secure wipe pass.
    var secureWipe: (@MainActor () -> Void)?

    /// Applies the prompt template to the active backend so the next
    /// generation uses the new session's format.
    var applyPromptTemplate: (@MainActor (PromptTemplate) -> Void)?

    /// Cancels and clears the runtime stream handle for the prior session.
    var cancelActiveStreamHandle: (@MainActor () async -> Void)?

    /// Resets per-session tool-approval state so approvals from the prior
    /// session do not leak into the new one.
    var resetToolApprovals: (@MainActor () -> Void)?

    /// Cancels any in-flight post-generation background task and clears the
    /// error surface.
    var cancelBackgroundTask: (@MainActor () -> Void)?

    /// Refreshes the available endpoint list from the configured endpoint store.
    var refreshAvailableEndpoints: (@MainActor () async -> Void)?

    // MARK: - Resolution helpers (closure-injected)

    /// Resolves a model ID to a `ModelInfo` in the current registry.
    var resolveModel: (@MainActor (UUID) -> ModelInfo?)?

    /// Resolves an endpoint ID to an `APIEndpointRecord` in the available list.
    var resolveEndpoint: (@MainActor (UUID) -> APIEndpointRecord?)?

    /// Applies a resolved model selection to `ChatViewModel`.
    var applyModelSelection: (@MainActor (ModelInfo?) -> Void)?

    /// Applies a resolved endpoint selection to `ChatViewModel`.
    var applyEndpointSelection: (@MainActor (APIEndpointRecord?) -> Void)?

    // MARK: - Session switching

    /// Teardown result describing what model and endpoint the new session
    /// stored, after all prior-session state has been cleared.
    struct TeardownResult {
        let resolvedModel: ModelInfo?
        let resolvedEndpoint: APIEndpointRecord?
    }

    /// Performs the teardown phase of a session switch, then returns the
    /// resolved model and endpoint from `selectionState`.
    ///
    /// Call order matters:
    /// 1. Discard inference requests for the prior session.
    /// 2. Reset conversation + KV cache on the active backend.
    /// 3. Cancel the runtime stream handle.
    /// 4. Reset tool-approval gate for the new session.
    /// 5. Cancel lingering background tasks.
    /// 6. Refresh the endpoint list (required before resolution in step 7).
    /// 7. Resolve stored model/endpoint IDs → live registry objects.
    ///
    /// `ChatViewModel+SessionManagement.switchToSession(_:)` wraps this in
    /// `isRestoringSession = true` / `false` and performs the remaining UI
    /// resets (input text, draft attachments, scroll state) that need
    /// `@MainActor` `ChatViewModel` state.
    func teardown(
        sessionID: UUID,
        promptTemplate: PromptTemplate,
        selectionState: SessionController.SessionSelectionState
    ) async -> TeardownResult {
        await discardRequests?(sessionID)
        resetConversation?()
        secureWipe?()
        applyPromptTemplate?(promptTemplate)
        await cancelActiveStreamHandle?()
        resetToolApprovals?()
        cancelBackgroundTask?()
        await refreshAvailableEndpoints?()

        let resolvedEndpoint = selectionState.selectedEndpointID.flatMap { resolveEndpoint?($0) }
        let resolvedModel = selectionState.selectedModelID.flatMap { resolveModel?($0) }

        return TeardownResult(resolvedModel: resolvedModel, resolvedEndpoint: resolvedEndpoint)
    }

    /// Applies the resolved model/endpoint selections after the teardown phase.
    ///
    /// Exactly one of `model` or `endpoint` will be set from the persisted
    /// session state; when neither was stored, both are cleared.
    func applySelection(_ result: TeardownResult) {
        if let endpoint = result.resolvedEndpoint {
            applyEndpointSelection?(endpoint)
        } else if let model = result.resolvedModel {
            applyModelSelection?(model)
        } else {
            applyModelSelection?(nil)
            applyEndpointSelection?(nil)
        }
    }
}
