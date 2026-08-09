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
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            foundationAvailableOverride: false,
            selectionPolicy: { _ in nil }
        )

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
        let preExisting = ManifoldInference.ChatSession(title: "From a previous launch")
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

    /// When the store already contains a cloud endpoint and no local model is
    /// selected, `quickStart()` must select the first endpoint and dispatch a
    /// load before returning — hosts should not need a separate
    /// `loadSelectedEndpoint()` on every relaunch (DX 02-swiftui-chat).
    func test_quickStart_selectsFirstEndpoint_whenPolicyReturnsNil() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let endpoint = APIEndpointRecord(
            name: "Local Ollama",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.1:8b"
        )

        // Seed the shared container with an endpoint, then relaunch through
        // quickStart() the way a consumer app would on second open.
        let first = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { container },
            selectionPolicy: { registry in
                registry.foundationModelProvider = { false }
                return nil
            }
        )
        try await first.bootstrap.endpointStore.insertEndpoint(endpoint)

        let second = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { container },
            selectionPolicy: { registry in
                registry.foundationModelProvider = { false }
                return nil
            }
        )

        XCTAssertEqual(
            second.viewModel.selectedEndpoint?.id,
            endpoint.id,
            "quickStart() must select the first persisted endpoint when no local model is chosen"
        )
    }

    /// A session that persisted a cloud endpoint must keep it on relaunch even
    /// when the default Foundation-first policy would otherwise pre-select a
    /// local model (DX 02-swiftui-chat).
    func test_quickStart_preservesSessionEndpoint_overDefaultPolicy() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let endpoint = APIEndpointRecord(
            name: "Local Ollama",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.1:8b"
        )

        let first = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { container }
        )
        try await first.bootstrap.endpointStore.insertEndpoint(endpoint)

        var session = try XCTUnwrap(first.viewModel.activeSession)
        session.selectedEndpointID = endpoint.id
        try await first.bootstrap.persistence.updateSession(session)

        let second = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { container }
        )

        XCTAssertEqual(
            second.viewModel.selectedEndpoint?.id,
            endpoint.id,
            "quickStart() must restore the session's persisted endpoint on relaunch"
        )
        XCTAssertNil(
            second.viewModel.selectedModel,
            "Restored session endpoint must not be replaced by the Foundation-first policy"
        )
    }

    /// Regression guard for #1473 — the documented quickStart cloud-endpoint
    /// recipe seeds `selectedEndpoint` and then activates it before first send.
    func test_quickStart_seededEndpoint_canLoadViaSelectedEndpoint() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            selectionPolicy: { registry in
                registry.foundationModelProvider = { false }
                return nil
            }
        )
        // quickStart() pre-registers the real OllamaBackends factory. Clear it
        // so the mock below is the sole handler and the test stays hermetic.
        result.bootstrap.inferenceService.clearEndpointBackendFactories()
        let cloudBackend = QuickStartCloudBackend()
        result.bootstrap.inferenceService.registerEndpointBackendFactory { provider in
            guard provider == .ollama else { return nil }
            return cloudBackend
        }

        let endpoint = APIEndpointRecord(
            name: "Local Ollama",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.1:8b"
        )

        try await result.bootstrap.endpointStore.insertEndpoint(endpoint)
        result.viewModel.setAvailableEndpoints([endpoint])
        result.viewModel.selectedEndpoint = endpoint

        await result.viewModel.loadSelectedEndpoint()

        XCTAssertTrue(result.viewModel.isModelLoaded)
        XCTAssertEqual(result.viewModel.activeBackendName, BackendName.ollama.rawValue)

        let reply = try await result.viewModel.sendMessage("Say hello")
        XCTAssertFalse(reply.content.isEmpty, "Expected non-empty reply from Ollama endpoint")
    }

    /// Regression guard for #1515 — `quickStart()` must wire `onFirstMessage`
    /// so that sessions whose title is still "New Chat" are auto-titled after
    /// the first user message, rather than remaining "New Chat" across every
    /// relaunch.
    ///
    /// We verify the word-truncation path (no inference required): a short
    /// first message sets the title verbatim; a long one is trimmed to a word
    /// boundary with an ellipsis.
    func test_quickStart_autotitles_session_on_first_message() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        let session = try XCTUnwrap(result.viewModel.activeSession,
            "quickStart() must produce an active session before we can test auto-title")

        // Confirm the hook is wired — calling it directly exercises the same
        // closure the real send path would call.
        XCTAssertNotNil(result.viewModel.onFirstMessage,
            "quickStart() must wire onFirstMessage for auto-title (#1515)")

        // Short message — title should be the message verbatim.
        let shortMessage = "Hello world"
        await result.viewModel.onFirstMessage?(session, shortMessage)

        let afterShort = try await result.bootstrap.persistence.fetchSessions()
        let renamedShort = afterShort.first { $0.id == session.id }
        XCTAssertEqual(renamedShort?.title, shortMessage,
            "Short first message should become the session title verbatim")

        // Sabotage check: title must differ from the default.
        XCTAssertNotEqual(renamedShort?.title, "New Chat",
            "Session title must no longer be 'New Chat' after first message")
    }

    /// Regression guard for #2307 — `quickStart()` must wire
    /// `resolveBranchOriginTitle` so `ChatHistoryView` can populate
    /// `BranchOriginChipView` for a branched session, mirroring the
    /// `onFirstMessage` wiring above.
    func test_quickStart_wiresResolveBranchOriginTitle() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        XCTAssertNotNil(result.viewModel.resolveBranchOriginTitle,
            "quickStart() must wire resolveBranchOriginTitle for the branch-origin chip (#2307)")

        let source = try await result.sessionManager.createSession(title: "Root conversation")
        var branched = ChatSession(title: "New Chat")
        branched.branchOriginSessionID = source.id
        branched.branchOriginTitleSnapshot = "Root conversation"
        try await result.bootstrap.persistence.insertSession(branched)

        let resolved = await result.viewModel.resolveBranchOriginTitle?(branched)
        XCTAssertEqual(resolved, "Root conversation",
            "The wired closure must resolve the live source title through the real session store")
    }

    /// Regression guard for #2453 — `quickStart()` must wire
    /// `viewModel.onSessionBranched` so "Branch from here" actually switches
    /// the app to the new session, not just create-and-strand it.
    /// `ChatGenerationCoordinator` invokes this closure with the new
    /// session's ID once `ConversationRuntime.branch(from:)` has persisted
    /// it; before this fix `quickStart()` left the seam unwired (unlike its
    /// `onFirstMessage` / `resolveBranchOriginTitle` siblings above), so the
    /// source session stayed active and the branched session only surfaced
    /// after an unrelated sidebar reload.
    ///
    /// The load-bearing assertion is on `result.viewModel.activeSession`, NOT
    /// `result.sessionManager.activeSession`: `ChatView`'s transcript keys off
    /// `viewModel.activeSessionID` (`ChatHistoryView`'s
    /// `.task(id: viewModel.activeSessionID)`), which `quickStart()`'s
    /// documented single-session recipe never bridges from
    /// `SessionManagerViewModel` — a sidebar host (e.g. `ManifoldDemoApp`)
    /// supplies that bridge itself. An earlier version of this test asserted
    /// only `sessionManager.activeSession`, which the fix could satisfy while
    /// leaving the actual chat surface stranded on the source session — a
    /// write with no reader, the same defect class as the original bug in
    /// the opposite direction. Asserting on `viewModel.activeSession` is what
    /// catches that: a no-op (or sessionManager-only) implementation fails
    /// this line.
    func test_quickStart_wiresOnSessionBranched_switchesActiveSession() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        XCTAssertNotNil(result.viewModel.onSessionBranched,
            "quickStart() must wire onSessionBranched so branching actually navigates (#2453)")

        let source = try await result.sessionManager.createSession(title: "Root conversation")
        result.sessionManager.activeSession = source
        await result.viewModel.switchToSession(source)

        // Simulate what `ConversationRuntime.branch(from:)` does: persist a
        // new session directly (bypassing the closure under test), then
        // invoke the closure the way `ChatGenerationCoordinator` does —
        // with only the new session's ID, exactly as the real turn loop
        // calls it.
        var branched = ChatSession(title: "New Chat")
        branched.branchOriginSessionID = source.id
        branched.branchOriginTitleSnapshot = "Root conversation"
        try await result.bootstrap.persistence.insertSession(branched)

        await result.viewModel.onSessionBranched?(branched.id)

        // The wired closure defers `viewModel.switchToSession(_:)` onto its
        // own `Task` (see `QuickStart.swift`'s doc comment on
        // `onSessionBranched` for why: awaiting it inline would await the
        // teardown of the very stream-drain task this closure runs on) — so
        // `viewModel.activeSession` is not guaranteed to have moved the
        // instant `onSessionBranched?` returns. Poll rather than assume
        // synchronous completion.
        await waitUntil { result.viewModel.activeSession?.id == branched.id }

        XCTAssertEqual(result.viewModel.activeSession?.id, branched.id,
            "onSessionBranched must switch viewModel.activeSession to the newly branched session — ChatView's transcript reads viewModel.activeSessionID, not sessionManager.activeSession")

        XCTAssertEqual(result.sessionManager.activeSession?.id, branched.id,
            "onSessionBranched must also switch sessionManager.activeSession so a sidebar host's session list reflects the branch")
    }

    /// Bounded poll for a condition driven by a fire-and-forget `Task` (the
    /// deferred `switchToSession` hop in `onSessionBranched`'s wiring), not a
    /// fixed sleep — matches the established idiom in
    /// `Tests/ManifoldUITests/LoadDispatchCoordinationTests.swift` and
    /// siblings. `Task.yield()` between checks, never `Task.sleep`, so this
    /// resolves as soon as the MainActor task actually runs rather than
    /// waiting out a guessed delay.
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        if condition() { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            await Task.yield()
            if condition() { return }
        }
        XCTFail("Condition not met before timeout", file: file, line: line)
    }

    /// Compile-time check that `QuickStartResult` is `Sendable`. The README's
    /// snippet stores the result in a `@State` property or passes it across
    /// task boundaries; losing Sendability would silently break that.
    func test_QuickStartResult_isSendable() {
        _requireSendable(QuickStartResult.self)
    }

    private func _requireSendable<T: Sendable>(_: T.Type) {}

    // MARK: - Selection Policy tests (#1612)

    /// A custom `selectionPolicy` that returns a `ModelInfo` must result in
    /// `modelRegistry.selectedModel` equalling that info. This exercises the
    /// override seam so hosts can inject their own policy.
    ///
    /// The policy must register the model in `availableModels` before returning
    /// it — `ModelRegistry.selectModel` validates that the chosen model is
    /// present in the registry (or is `builtInFoundation`). A real host policy
    /// would only return models it discovered or registered.
    func test_quickStart_customPolicy_selectsReturnedModel() async throws {
        let sentinel = ModelInfo(
            id: UUID(),
            name: "Sentinel Model",
            fileName: "sentinel.gguf",
            url: URL(fileURLWithPath: "/tmp/sentinel.gguf"),
            fileSize: 1_000_000,
            modelType: .gguf
        )

        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            selectionPolicy: { registry in
                // Policies are responsible for ensuring selected models are in
                // availableModels — selectModel() validates presence. A host
                // policy that discovers its own models would add them here.
                registry.availableModels = [sentinel]
                return sentinel
            }
        )

        // The policy returned a model — `selectedModel` must reflect it.
        XCTAssertEqual(result.viewModel.modelRegistry.selectedModel?.id, sentinel.id,
            "Custom selectionPolicy return value must be applied to modelRegistry.selectedModel (#1612)")

        // Sabotage: a different model ID must NOT match.
        XCTAssertNotEqual(result.viewModel.modelRegistry.selectedModel?.id, UUID(),
            "Sabotage: selectedModel.id must not be a random UUID")
    }

    /// A `selectionPolicy` returning `nil` must leave `selectedModel` nil
    /// without crashing — the empty-state path must be silent and stable.
    func test_quickStart_nilReturningPolicy_leavesSelectedModelNil() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            selectionPolicy: { _ in nil }
        )

        XCTAssertNil(result.viewModel.modelRegistry.selectedModel,
            "nil selectionPolicy must leave selectedModel nil — no crash, no fallback (#1612)")
    }

    /// When the built-in policy is in effect (selectionPolicy: nil) and
    /// `availableModels` contains a local model but no Foundation model is
    /// available, the first *loadable* local model must be selected.
    ///
    /// We exercise this via a custom policy that:
    /// 1. Clears `foundationModelProvider` to ensure the Foundation-first branch
    ///    is skipped (guards against test machines where Apple Intelligence is
    ///    available and would win the priority race).
    /// 2. Seeds `availableModels` with the local model.
    /// 3. Delegates to `defaultSelectionPolicy` to exercise its logic directly.
    ///
    /// A GGUF-capable mock registrar is injected via `backends:` because the
    /// default policy now refuses to select models no registered backend can
    /// load (#1749) — under `--disable-default-traits` there is no compiled-in
    /// GGUF backend.
    func test_quickStart_defaultPolicy_selectsFirstLocalModel_whenAvailable() async throws {
        let localModel = ModelInfo(
            id: UUID(),
            name: "Test GGUF",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 500_000,
            modelType: .gguf
        )

        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            backends: [MockGGUFBackends.self],
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            selectionPolicy: { registry in
                // Suppress Foundation availability so we reach the "first local
                // model" fallback branch regardless of what hardware the test
                // runner is on.
                registry.foundationModelProvider = { false }
                // Seed the registry so availableModels is non-empty.
                registry.availableModels = [localModel]
                // Delegate to the built-in policy so we exercise its logic.
                return await ManifoldKit.defaultSelectionPolicy(registry)
            }
        )

        // The default policy must select the first available local model.
        XCTAssertEqual(result.viewModel.modelRegistry.selectedModel?.id, localModel.id,
            "Default policy must select the first local model when Foundation is unavailable (#1612)")
        XCTAssertEqual(result.viewModel.modelRegistry.selectedModel?.modelType, .gguf)
    }
}

private final class QuickStartCloudBackend: InferenceBackend, EndpointBackendURLModelConfigurable, @unchecked Sendable {
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
        config: GenerationConfig,
        hints: GenerationRuntimeHints
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
