// QuickStartTests.swift
//
// Exercises `ManifoldKit.quickStart()` — the one-call facade that collapses
// the documented three-object bootstrap dance. The README's getting-started
// snippet depends on this returning a working `ChatViewModel` + bootstrap
// pair, and on errors surfacing through the unified `ManifoldKitError` rim
// rather than raw underlying errors.

import XCTest
import SwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldKit

@MainActor
final class QuickStartTests: XCTestCase {

    /// The happy path: `quickStart()` returns a bootstrap, a view model, and
    /// a session manager that share the same inference service and have
    /// persistence wired up.
    ///
    /// We use the internal `_quickStart` seam with an in-memory SwiftData
    /// container so the test doesn't touch the on-disk Application Support
    /// store the default factory derives.
    func test_quickStart_returnsBootstrappedViewModelAndSessionManager() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        // Bootstrap side: every service the facade promises was constructed.
        // `ChatViewModel.inferenceService` is intentionally `internal` to
        // ManifoldUI (see CLAUDE.md "Service sharing"), so we can't assert
        // reference identity from this test target — instead we check that
        // the bootstrap exposes the shared services the view model was
        // configured against.
        XCTAssertNotNil(result.bootstrap.persistence)
        XCTAssertNotNil(result.bootstrap.conversationRuntime)
        XCTAssertNotNil(result.bootstrap.endpointStore)

        // View-model side: observable surface area is wired. `modelRegistry`
        // is the documented sibling-module read seam (CLAUDE.md "Service
        // sharing") and is populated from the inference service the
        // bootstrap built.
        XCTAssertNotNil(result.viewModel.modelRegistry)

        // Session-manager side (#1425/#1447): `sessionManager` is wired and
        // sessions are populated the moment quickStart() returns — no polling
        // or extra loadSessions() call needed.
        XCTAssertFalse(result.sessionManager.sessions.isEmpty,
            "sessionManager.sessions must be populated immediately after quickStart() returns (no polling required) — regression guard for #1447")
    }

    /// Errors from any step in the bootstrap chain must be reduced through
    /// `ManifoldKitError.from(_:)` rather than leaking the raw underlying
    /// error. We force a failure by passing a throwing model-container
    /// factory and assert the caught error is `ManifoldKitError`.
    func test_quickStart_surfacesManifoldKitError_onFailure() async {
        struct ForcedFailure: Error {}

        do {
            _ = try await ManifoldKit._quickStart(
                configuration: .default,
                makeModelContainer: { throw ForcedFailure() }
            )
            XCTFail("quickStart() must throw when the model container factory throws.")
        } catch let error as ManifoldKitError {
            // Unknown errors fall through to .unknown — that's the expected
            // case for a synthetic test error that doesn't match any of the
            // structured URLError / DecodingError / KeychainError shapes.
            switch error {
            case .unknown:
                break
            default:
                XCTFail("Expected .unknown ManifoldKitError, got \(error).")
            }
        } catch {
            XCTFail("Expected ManifoldKitError, got \(type(of: error)): \(error). The facade must wrap all underlying errors through ManifoldKitError.from(_:).")
        }
    }

    /// Regression guard for A2-F4 — the documented `quickStart()` →
    /// `ChatView()` happy path must produce a usable chat surface on first
    /// launch. `ChatView` disables its composer whenever
    /// `viewModel.activeSession == nil`; prior to this fix a fresh consumer
    /// with no persisted sessions saw "No session selected" and could not
    /// chat without diving into `Example/Advanced/` for `createSession()`.
    func test_quickStart_autoCreatesInitialSession_whenStoreIsEmpty() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        // The invariant: a fresh consumer of quickStart() has a usable chat
        // surface — activeSession is non-nil, which is what ChatView keys
        // composer-enabled state off of.
        XCTAssertNotNil(
            result.viewModel.activeSession,
            "quickStart() must auto-create an initial session so ChatView's composer is enabled on first launch (A2-F4)."
        )

        // And the session is already visible in sessionManager.sessions (#1425,
        // #1447) — no additional loadSessions() or polling needed.
        let persisted = try await result.bootstrap.persistence.fetchSessions()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.id, result.viewModel.activeSession?.id)
        XCTAssertEqual(result.sessionManager.sessions.count, 1,
            "sessionManager.sessions must reflect the auto-created session immediately (#1447)")
        XCTAssertEqual(result.sessionManager.sessions.first?.id, result.viewModel.activeSession?.id,
            "sessionManager and viewModel must share the same active session")
    }

    /// Symmetric guard: when persistence already contains sessions (e.g.
    /// relaunch, restored backup, host app that wired its own session
    /// creation before calling quickStart) the facade must not add a stray
    /// "New Chat" row — instead it selects the existing most-recent session.
    func test_quickStart_selectsExistingSession_whenStoreIsNonEmpty() async throws {
        // Pre-seed the same on-disk path with a session. We use a shared
        // in-memory container by sharing the makeModelContainer closure
        // across two quickStart calls — but the in-memory factory makes a
        // *new* container each call, so instead we drive the bootstrap once,
        // create a session manually, then call quickStart again against
        // the same container via the internal seam.
        //
        // Simpler: drive _quickStart twice with a container the test owns.
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let firstResult = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { container }
        )
        let firstSessionID = try XCTUnwrap(firstResult.viewModel.activeSession?.id)

        // Insert a second, more-recent session directly through the
        // persistence port so we can verify "selects the existing
        // most-recent" rather than "always creates a fresh one".
        let preExisting = ChatSessionRecord(title: "From a previous launch")
        try await firstResult.bootstrap.persistence.insertSession(preExisting)

        let secondResult = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { container }
        )

        // Exactly the two sessions we expect — no third one auto-created on
        // the second launch.
        let persisted = try await secondResult.bootstrap.persistence.fetchSessions()
        XCTAssertEqual(persisted.count, 2)
        let persistedIDs = Set(persisted.map(\.id))
        XCTAssertTrue(persistedIDs.contains(firstSessionID))
        XCTAssertTrue(persistedIDs.contains(preExisting.id))

        // And the view model picked one of them rather than minting a new id.
        let active = try XCTUnwrap(secondResult.viewModel.activeSession)
        XCTAssertTrue(persistedIDs.contains(active.id))

        // sessionManager also reflects both sessions without extra loadSessions()
        // calls — #1447 guarantee applies to the relaunch path too.
        XCTAssertEqual(secondResult.sessionManager.sessions.count, 2,
            "sessionManager.sessions must reflect persisted sessions on relaunch immediately (#1447)")
    }

    /// Regression guard for #1473 — the documented quickStart cloud-endpoint
    /// recipe seeds `selectedEndpoint` and then activates it before first send.
    func test_quickStart_seededEndpoint_canLoadViaSelectedEndpoint() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        let cloudBackend = QuickStartCloudBackend()
        result.bootstrap.inferenceService.registerCloudBackendFactory { provider in
            guard provider == .ollama else { return nil }
            return cloudBackend
        }

        let endpoint = APIEndpointRecord(
            name: "Local Ollama",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2:3b"
        )

        try await result.bootstrap.endpointStore.insertEndpoint(endpoint)
        result.viewModel.setAvailableEndpoints([endpoint])
        result.viewModel.selectedEndpoint = endpoint

        await result.viewModel.loadSelectedEndpoint()

        XCTAssertTrue(result.viewModel.isModelLoaded)
        XCTAssertEqual(result.viewModel.activeBackendName, BackendName.ollama.rawValue)

        let reply = try await result.viewModel.sendMessage("Say hello")
        XCTAssertEqual(reply.content, "Hello cloud")
    }

    /// Compile-time check that `QuickStartResult` is `Sendable`. The README's
    /// snippet stores the result in a `@State` property or passes it across
    /// task boundaries; losing Sendability would silently break that.
    func test_QuickStartResult_isSendable() {
        _requireSendable(QuickStartResult.self)
    }

    private func _requireSendable<T: Sendable>(_: T.Type) {}
}

private final class QuickStartCloudBackend: InferenceBackend, CloudBackendURLModelConfigurable, @unchecked Sendable {
    var isModelLoaded = false
    var isGenerating = false
    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    func configure(baseURL: URL, modelName: String) {}

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        guard isModelLoaded else {
            throw InferenceError.inferenceFailure("No model loaded")
        }
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.yield(.token("Hello cloud"))
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {}

    func unloadModel() {
        isModelLoaded = false
    }
}
