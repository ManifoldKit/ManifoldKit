// QuickStartRespondTests.swift
//
// Exercises the one-shot `QuickStartResult.respond(to:)` collect helper
// (#1942, partial) — the convenience that drains a single streamed turn to
// its terminal assistant text. Uses a real in-memory SwiftData store plus
// `MockInferenceBackend` so the full ChatViewModel → ConversationRuntime
// pipeline executes without hardware dependencies.
//
// The duplicate unlabeled `respond(_:)` spelling this suite originally
// exercised was removed in the 2026-07 API review (item 2.4) — both
// spellings terminated in `sendMessage(text).content` with no behavioral
// divergence, so `respond(to:)` (the Swift-API-guidelines spelling already
// used by `ChatViewModel.respond(to:)` and `LLM.respond(to:)`) is now the
// single surviving form. This suite still covers the same accumulation and
// error-propagation contract, just through the surviving spelling.

import XCTest
import SwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldUI
import ManifoldTestSupport
@testable import ManifoldKit

@MainActor
final class QuickStartRespondTests: XCTestCase {

    /// Builds a `QuickStartResult` over an in-memory bootstrap whose inference
    /// service is backed by `mock`, with one active session wired through the
    /// shared ConversationRuntime — mirroring what `_quickStart` assembles.
    private func makeResult(mock: MockInferenceBackend) async throws -> QuickStartResult {
        let service = InferenceService(backend: mock, name: "MockRespond")
        let bootstrap = try ManifoldBootstrap.makeInMemory(
            configuration: .default,
            inferenceService: service
        )

        let viewModel = ChatViewModel(
            inferenceService: bootstrap.inferenceService,
            conversationRuntime: bootstrap.conversationRuntime
        )
        viewModel.configure(persistence: bootstrap.persistence)

        let sessionManager = SessionManagerViewModel()
        await sessionManager.configureAndLoad(bootstrap: bootstrap)

        let session = ManifoldInference.ChatSession(title: "Respond Test")
        try await bootstrap.persistence.insertSession(session)
        sessionManager.activeSession = session
        await viewModel.switchToSession(session)

        return QuickStartResult(
            bootstrap: bootstrap,
            viewModel: viewModel,
            sessionManager: sessionManager
        )
    }

    /// The core contract: `respond` returns the mock backend's *full*
    /// accumulated text, not a single token or a partial prefix. The mock
    /// emits a multi-token string so a dropped-accumulation regression
    /// (returning only the first token) fails this assertion.
    func test_respond_returnsFullAccumulatedAssistantText() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Hello", ", ", "from", " ", "the", " mock"]

        let result = try await makeResult(mock: mock)

        let answer = try await result.respond(to: "hi")

        XCTAssertEqual(
            answer,
            "Hello, from the mock",
            "respond(to:) must return the full concatenation of every streamed token — dropping the accumulation would return only a partial prefix."
        )
    }

    /// Error propagation: when the backend fails the turn, `respond` surfaces
    /// the typed `SendMessageError` from the underlying `sendMessage(_:)`
    /// rather than swallowing it and returning empty text. The mock is loaded
    /// (so the turn dispatches) but throws inside generation.
    func test_respond_propagatesSendMessageError_onBackendFailure() async throws {
        struct ForcedGenerationFailure: Error {}

        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.shouldThrowOnGenerate = ForcedGenerationFailure()

        let result = try await makeResult(mock: mock)

        do {
            _ = try await result.respond(to: "hi")
            XCTFail("respond(to:) must throw when the backend fails the turn, not return empty text.")
        } catch is SendMessageError {
            // Expected: the typed error rim is preserved through respond(to:).
        }
    }
}
