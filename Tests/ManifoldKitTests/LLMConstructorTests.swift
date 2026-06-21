// LLMConstructorTests.swift
//
// Exercises the value-typed `LLM(from:template:)` front door (#1942 D2) — the
// two-line entry point that wraps `quickStart` plumbing and exposes a
// String-typed `respond(to:)`. Uses the `package` test seam (a pre-assembled
// `QuickStartResult` over an in-memory bootstrap + `MockInferenceBackend`) so no
// real model download is required, mirroring `QuickStartRespondTests`.

import XCTest
import SwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldUI
import ManifoldTestSupport
@testable import ManifoldKit

@MainActor
final class LLMConstructorTests: XCTestCase {

    /// Builds a `QuickStartResult` over an in-memory bootstrap whose inference
    /// service is backed by `mock`, with one active session — exactly what
    /// `_quickStart` assembles, minus the model download.
    private func makeResult(mock: MockInferenceBackend) async throws -> QuickStartResult {
        let service = InferenceService(backend: mock, name: "MockLLM")
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

        let session = ManifoldInference.ChatSession(title: "LLM Test")
        try await bootstrap.persistence.insertSession(session)
        sessionManager.activeSession = session
        await viewModel.switchToSession(session)

        return QuickStartResult(
            bootstrap: bootstrap,
            viewModel: viewModel,
            sessionManager: sessionManager
        )
    }

    /// Happy path: an `LLM` constructs over the test seam and `respond(to:)`
    /// returns the mock's full accumulated reply.
    func test_respond_returnsMockReply() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Mon", "ads", " are ", "monoids"]

        let result = try await makeResult(mock: mock)
        let llm = LLM(result: result)

        let answer = try await llm.respond(to: "Explain monads")

        XCTAssertEqual(
            answer,
            "Monads are monoids",
            "LLM.respond(to:) must return the full concatenation of every streamed token from the wrapped ChatViewModel."
        )
    }

    /// Error propagation: when the backend fails the turn, the same typed
    /// `SendMessageError` D1 surfaces propagates out of the value-typed front
    /// door rather than being swallowed.
    func test_respond_propagatesSendMessageError() async throws {
        struct ForcedGenerationFailure: Error {}

        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.shouldThrowOnGenerate = ForcedGenerationFailure()

        let result = try await makeResult(mock: mock)
        let llm = LLM(result: result)

        do {
            _ = try await llm.respond(to: "hi")
            XCTFail("LLM.respond(to:) must throw when the backend fails the turn, not return empty text.")
        } catch let error as SendMessageError {
            // A backend generate-time failure surfaces as .runtime — the ConversationRuntime
            // wraps the underlying error rather than re-typing it. Asserting the specific
            // case (not just the type) catches regressions where the wrong case propagates.
            guard case .runtime = error else {
                return XCTFail("Expected SendMessageError.runtime, got \(error)")
            }
        }
    }

    /// Template wiring (built-in path): a supplied `ChatTemplate(builtIn:)` is
    /// applied to the live render path via `selectedPromptTemplate`.
    func test_builtInTemplate_appliesToRenderPath() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true

        let result = try await makeResult(mock: mock)
        // Default is .chatML; pick a distinct family so a no-op wiring fails.
        XCTAssertNotEqual(result.viewModel.selectedPromptTemplate, .llama3)

        let llm = LLM(result: result, template: ChatTemplate(builtIn: .llama3))

        XCTAssertEqual(
            llm.viewModel.selectedPromptTemplate,
            .llama3,
            "A ChatTemplate(builtIn:) must be applied to the wrapped ChatViewModel's selectedPromptTemplate."
        )
    }

    /// Template override survives the async model-load clobber. `quickStart`
    /// dispatches the model load *after* it returns; a local-GGUF load's
    /// metadata auto-detect fires `onSetSelectedPromptTemplate` and overwrites
    /// the override `init` applied. Simulate that post-construction clobber, then
    /// assert `respond(to:)` re-asserts the caller's built-in template before the
    /// turn so the renderer sees the override — not the model-detected default.
    func test_builtInTemplate_survivesPostLoadClobber() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["ok"]

        let result = try await makeResult(mock: mock)
        let llm = LLM(result: result, template: ChatTemplate(builtIn: .llama3))
        XCTAssertEqual(llm.viewModel.selectedPromptTemplate, .llama3)

        // Simulate the async model load completing and clobbering the override
        // via the coordinator's `onSetSelectedPromptTemplate` seam.
        result.viewModel.selectedPromptTemplate = .gemma
        XCTAssertEqual(
            llm.viewModel.selectedPromptTemplate,
            .gemma,
            "Precondition: the simulated load clobbered the override."
        )

        _ = try await llm.respond(to: "hi")

        XCTAssertEqual(
            llm.viewModel.selectedPromptTemplate,
            .llama3,
            "respond(to:) must re-assert the caller's built-in template on the turn path so the async-load clobber does not win."
        )
    }

    /// Template wiring (embedded-Jinja path, deferred): passing an embedded
    /// template does not break construction and leaves the prompt template
    /// untouched (the raw channel has no public injection seam yet).
    func test_embeddedJinjaTemplate_doesNotBreakConstruction() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true

        let result = try await makeResult(mock: mock)
        let original = result.viewModel.selectedPromptTemplate

        let llm = LLM(
            result: result,
            template: ChatTemplate(embeddedJinja: "{{ messages }}")
        )

        XCTAssertEqual(
            llm.viewModel.selectedPromptTemplate,
            original,
            "An embedded-Jinja ChatTemplate has no public injection seam yet (TODO #1942 D2); it must not alter selectedPromptTemplate."
        )
    }
}
