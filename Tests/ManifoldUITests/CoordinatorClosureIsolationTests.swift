import XCTest
import ManifoldInference
import ManifoldRuntime
@testable import ManifoldUI

@MainActor
final class CoordinatorClosureIsolationTests: XCTestCase {

    func test_modelLoadCoordinatorClosureSeamsAreMainActorIsolated_compileOnly() {
        let coordinator = ModelLoadCoordinator(inferenceService: InferenceService())

        acceptsMainActorTransition(coordinator.onTransitionPhase)
        acceptsMainActorStringErrorWriter(coordinator.onSurfaceError)
        acceptsMainActorVoid(coordinator.onClearError)
        acceptsMainActorPromptTemplateWriter(coordinator.onSetSelectedPromptTemplate)
        acceptsMainActorVoid(coordinator.onInvalidateTokenCaches)
        acceptsMainActorBoolReader(coordinator.isRestoringSession)
        acceptsMainActorPhaseReader(coordinator.currentActivityPhase)
        acceptsMainActorLoadEnvironmentReader(coordinator.currentLoadPlanEnvironment)
    }

    func test_generationCoordinatorClosureSeamsAreMainActorIsolated_compileOnly() {
        let coordinator = ChatGenerationCoordinator(
            conversationRuntime: ConversationRuntime(
                messageStore: InMemoryMessageStore(),
                inferenceService: InferenceService()
            ),
            ownsDefaultRuntime: true
        )

        acceptsMainActorTransition(coordinator.onTransitionPhase)
        acceptsMainActorTurnStateWriter(coordinator.onSetLastTurnState)
        acceptsMainActorOptionalErrorWriter(coordinator.onSetBackgroundTaskError)
        acceptsMainActorThinkingIDsWriter(coordinator.onSetMessageIDsWithStreamingThinking)
        acceptsMainActorOptionalUUIDReader(coordinator.currentActiveSessionID)
        acceptsMainActorOptionalSessionReader(coordinator.currentActiveSession)
        acceptsMainActorMessagesReader(coordinator.currentMessages)
        acceptsMainActorPostTasksReader(coordinator.currentPostGenerationTasks)
        acceptsMainActorMessageMutator(coordinator.mutateMessage)
        acceptsMainActorMessageAppender(coordinator.appendMessage)
        acceptsMainActorMessageRemover(coordinator.removeMessages)
        acceptsMainActorVoid(coordinator.updateContextEstimate)
        acceptsMainActorErrorSurface(coordinator.surfaceError)
        acceptsMainActorOptionalStringWriter(coordinator.setErrorMessage)
        acceptsMainActorBoolWriter(coordinator.setShowUpgradeHint)
    }
}

private func acceptsMainActorTransition(_ closure: @MainActor (BackendActivityPhase) -> Bool) {
    _ = closure
}

private func acceptsMainActorStringErrorWriter(_ closure: @MainActor (String, any Error) -> Void) {
    _ = closure
}

private func acceptsMainActorOptionalStringWriter(_ closure: @MainActor (String?) -> Void) {
    _ = closure
}

private func acceptsMainActorVoid(_ closure: @MainActor () -> Void) {
    _ = closure
}

private func acceptsMainActorPromptTemplateWriter(_ closure: @MainActor (PromptTemplate) -> Void) {
    _ = closure
}

private func acceptsMainActorBoolReader(_ closure: @MainActor () -> Bool) {
    _ = closure
}

private func acceptsMainActorPhaseReader(_ closure: @MainActor () -> BackendActivityPhase) {
    _ = closure
}

private func acceptsMainActorLoadEnvironmentReader(_ closure: @MainActor () -> ModelLoadPlan.Environment) {
    _ = closure
}

private func acceptsMainActorTurnStateWriter(_ closure: @MainActor (ChatViewModel.TurnState) -> Void) {
    _ = closure
}

private func acceptsMainActorOptionalErrorWriter(_ closure: @MainActor (Error?) -> Void) {
    _ = closure
}

private func acceptsMainActorThinkingIDsWriter(_ closure: @MainActor (Set<UUID>) -> Void) {
    _ = closure
}

private func acceptsMainActorOptionalUUIDReader(_ closure: @MainActor () -> UUID?) {
    _ = closure
}

private func acceptsMainActorOptionalSessionReader(_ closure: @MainActor () -> ChatSession?) {
    _ = closure
}

private func acceptsMainActorMessagesReader(_ closure: @MainActor () -> [ChatMessage]) {
    _ = closure
}

private func acceptsMainActorPostTasksReader(_ closure: @MainActor () -> [any PostGenerationTask]) {
    _ = closure
}

private func acceptsMainActorMessageMutator(
    _ closure: @MainActor (UUID, (inout ChatMessage) -> Void) -> Bool
) {
    _ = closure
}

private func acceptsMainActorMessageAppender(_ closure: @MainActor (ChatMessage) -> Void) {
    _ = closure
}

private func acceptsMainActorMessageRemover(_ closure: @MainActor ((ChatMessage) -> Bool) -> Void) {
    _ = closure
}

private func acceptsMainActorErrorSurface(_ closure: @MainActor (any Error, ChatError.Kind) -> Void) {
    _ = closure
}

private func acceptsMainActorBoolWriter(_ closure: @MainActor (Bool) -> Void) {
    _ = closure
}
