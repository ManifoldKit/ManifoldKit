import XCTest
import os
@testable import ManifoldInference

/// Unit tests for ``ModelLifecycleCoordinator``'s load-token lifecycle.
///
/// The coordinator's `beginLoadRequest`, `canCommitLoad`, `invalidateOutstandingLoads`,
/// `finishLoadAttemptWithSuccess`, and `finishLoadAttemptWithFailure` methods are all
/// private. These tests exercise them indirectly through the public/internal API:
/// `loadModel(from:)`, `loadEndpointBackend(from:)`, and `unloadModel()`, then assert
/// on the observable state properties (`isModelLoaded`, `activeBackendName`,
/// `modelLoadProgress`).
///
/// Each test verifies that a sabotage would flip the assertion — confirming
/// the assertion actually covers the code path under test.
@MainActor
final class ModelLifecycleCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeModelInfo(name: String = "Test", modelType: ModelType = .gguf) -> ModelInfo {
        let (fileName, url): (String, URL) = {
            switch modelType {
            case .gguf:
                let fileName = "\(name).gguf"
                return (fileName, URL(fileURLWithPath: "/\(fileName)"))
            case .mlx:
                return (name, URL(fileURLWithPath: "/\(name)"))
            case .foundation:
                return ("/", URL(fileURLWithPath: "/"))
            default:
                return (name, URL(fileURLWithPath: "/\(name)"))
            }
        }()
        return ModelInfo(
            name: name,
            fileName: fileName,
            url: url,
            fileSize: 0,
            modelType: modelType
        )
    }

    /// Creates a fresh ``ModelLifecycleCoordinator`` with a gated backend
    /// factory pre-registered for a single model type.
    private func makeCoordinatorAndGate(modelType: ModelType = .gguf) -> (ModelLifecycleCoordinator, GatedLoadBackend) {
        let coordinator = ModelLifecycleCoordinator()
        let backend = GatedLoadBackend()
        coordinator.registerBackendFactory { type in
            type == modelType ? backend : nil
        }
        return (coordinator, backend)
    }

    // MARK: - 1. Basic load commit

    /// A load request that finishes without interruption must flip `isModelLoaded`
    /// to `true` and surface the backend name.
    ///
    /// Sabotage: removing `GatedLoadBackend.releaseSuccess()` (so `loadModel` never
    /// returns) causes the test to hang waiting for the result. Alternatively,
    /// making `commitLoadIfCurrent` always return `false` would leave `isModelLoaded = false`.
    func test_basicLoadCommit_setsIsModelLoadedAndBackendName() async throws {
        let (coordinator, backend) = makeCoordinatorAndGate()

        let task = Task { try await coordinator.loadModel(from: makeModelInfo()) }
        await backend.waitUntilLoadStarted()

        // While the load is in-flight, the model is not yet committed.
        XCTAssertFalse(coordinator.isModelLoaded, "Model must not be marked loaded until the commit succeeds")

        await backend.releaseSuccess()
        try await task.value

        XCTAssertTrue(coordinator.isModelLoaded, "isModelLoaded must flip to true after successful commit")
        XCTAssertEqual(coordinator.activeBackendName, BackendName.llama.rawValue,
                       "activeBackendName must reflect the backend that committed the load")
        XCTAssertEqual(coordinator.activeModelName, "Test",
                       "activeModelName must be set from ModelInfo.name at commit time")
    }

    // MARK: - 1b. Plan-taking overload commits identically

    /// The plan-taking overload must drive the same commit lifecycle as the
    /// legacy contextSize overload. This verifies Stage 3's refactor didn't
    /// break the delegation path.
    ///
    /// Sabotage: changing `loadModel(from:plan:)` to skip `commitLoadIfCurrent`
    /// would leave `isModelLoaded = false` and fail the assertion below.
    func test_planLoad_commitsIdentically() async throws {
        let (coordinator, backend) = makeCoordinatorAndGate()
        let modelInfo = makeModelInfo()
        let plan = ModelLoadPlan.compute(
            for: modelInfo,
            requestedContextSize: 2048,
            strategy: .mappable
        )

        let task = Task { try await coordinator.loadModel(from: modelInfo, plan: plan) }
        await backend.waitUntilLoadStarted()
        await backend.releaseSuccess()
        try await task.value

        XCTAssertTrue(coordinator.isModelLoaded,
                      "Plan-taking overload must flip isModelLoaded on successful commit")
        XCTAssertEqual(coordinator.activeBackendName, BackendName.llama.rawValue)
        XCTAssertEqual(coordinator.activeModelName, "Test")
    }

    /// A plan with `verdict == .deny` must throw `memoryInsufficient` before
    /// ever dispatching to the backend — no load task should start.
    ///
    /// Sabotage: deleting the `.deny` throw branch would let the load proceed
    /// and either commit or block on the gated backend.
    func test_planLoad_deniedPlan_throwsMemoryInsufficient() async throws {
        let (coordinator, backend) = makeCoordinatorAndGate()
        coordinator.denyPolicy = .throwError   // pin policy — platformDefault is .warnOnly on macOS and would downgrade .deny to proceed, hanging the GatedLoadBackend
        let modelInfo = makeModelInfo()

        // Synthesize a plan whose inputs force a deny verdict.
        let denied = ModelLoadPlan.compute(inputs: ModelLoadPlan.Inputs(
            modelFileSize: 64 * 1_073_741_824,   // 64 GB model
            memoryStrategy: .resident,
            requestedContextSize: 4096,
            trainedContextLength: nil,
            kvBytesPerToken: 8_192,
            availableMemoryBytes: 1_073_741_824, // 1 GB available — model won't fit
            physicalMemoryBytes: 1_073_741_824,
            absoluteContextCeiling: 128_000,
            headroomFraction: 0.40
        ))
        XCTAssertEqual(denied.verdict, .deny,
                       "Test setup: crafted inputs must produce a deny verdict")

        do {
            try await coordinator.loadModel(from: modelInfo, plan: denied)
            XCTFail("Denied plan must throw before calling into the backend")
        } catch let error as InferenceError {
            if case .memoryInsufficient = error {
                // Expected
            } else {
                XCTFail("Expected memoryInsufficient, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertFalse(coordinator.isModelLoaded)
        // Backend must not have been invoked.
        XCTAssertFalse(backend.isModelLoaded)
    }

    // MARK: - 2. Stale load suppressed

    /// When request B supersedes request A (B starts after A), A's completion
    /// must be silently discarded — `isModelLoaded` stays false until B commits.
    ///
    /// Sabotage: if the `invalidatedThroughToken` guard is removed from `canCommitLoad`,
    /// request A would commit and overwrite request B's state.
    func test_staleLoad_isDiscardedWhenSuperseded() async throws {
        let (coordinator, firstBackend) = makeCoordinatorAndGate(modelType: .gguf)
        let secondBackend = GatedLoadBackend()
        coordinator.registerBackendFactory { type in type == .foundation ? secondBackend : nil }

        // Start request A.
        let taskA = Task {
            try await coordinator.loadModel(from: makeModelInfo(name: "A", modelType: .gguf))
        }
        await firstBackend.waitUntilLoadStarted()

        // Start request B, which supersedes A.
        let taskB = Task {
            try await coordinator.loadModel(from: makeModelInfo(name: "B", modelType: .foundation))
        }
        await secondBackend.waitUntilLoadStarted()

        // Request B is now the latest. Let A succeed — it must be treated as stale.
        await firstBackend.releaseSuccess()
        _ = try? await taskA.value   // A completes; result is suppressed.

        // Model must NOT be committed from A's stale success.
        XCTAssertFalse(coordinator.isModelLoaded,
                       "A stale success from request A must not commit the model")

        // Let B succeed — it must commit normally.
        await secondBackend.releaseSuccess()
        try await taskB.value

        XCTAssertTrue(coordinator.isModelLoaded,
                      "Request B must commit successfully after A was suppressed")
        XCTAssertEqual(coordinator.activeBackendName, BackendName.foundation.rawValue,
                       "activeBackendName must reflect B's backend, not A's")
    }

    // MARK: - 3. Rapid load-unload-load

    /// `invalidateOutstandingLoads()` (called by `unloadModel()`) raises the
    /// invalidation watermark so that any in-flight request becomes stale.
    /// A subsequent load started after the unload must commit normally.
    ///
    /// Sabotage: removing the `invalidatedThroughToken` guard from `canCommitLoad`
    /// would allow A to commit after `unloadModel()`, leaving the coordinator in
    /// a loaded state with a model the caller thought was unloaded.
    func test_rapidLoadUnloadLoad_oldRequestSuppressedNewCommits() async throws {
        let (coordinator, firstBackend) = makeCoordinatorAndGate(modelType: .gguf)
        let secondBackend = GatedLoadBackend()
        coordinator.registerBackendFactory { type in type == .foundation ? secondBackend : nil }

        // Start request A.
        let taskA = Task {
            try await coordinator.loadModel(from: makeModelInfo(name: "A", modelType: .gguf))
        }
        await firstBackend.waitUntilLoadStarted()

        // Unload immediately — invalidates A's token.
        coordinator.unloadModel()

        // Start request B.
        let taskB = Task {
            try await coordinator.loadModel(from: makeModelInfo(name: "B", modelType: .foundation))
        }
        await secondBackend.waitUntilLoadStarted()

        // Let A succeed now — it must be treated as stale.
        await firstBackend.releaseSuccess()
        _ = try? await taskA.value

        // B is in-flight; model not yet loaded.
        XCTAssertFalse(coordinator.isModelLoaded,
                       "Stale A must not commit after unloadModel() invalidated it")

        // Let B succeed.
        await secondBackend.releaseSuccess()
        try await taskB.value

        XCTAssertTrue(coordinator.isModelLoaded,
                      "Request B must commit cleanly after A was invalidated by unloadModel()")
    }

    // MARK: - 4. Mismatched phase suppression (same as scenario 2, explicit token ordering)

    /// When two loads overlap, only the latest-started request's token matches
    /// `latestRequestedLoadToken`. The earlier token's `canCommitLoad` check
    /// must return `false` because the token no longer matches the latest.
    ///
    /// This is a focused re-verification of the `latestRequestedLoadToken == request`
    /// guard rather than the `invalidatedThroughToken` guard.
    ///
    /// Sabotage: if the `latestRequestedLoadToken == request` guard were removed
    /// from `canCommitLoad`, the first-completing request would always commit
    /// regardless of ordering.
    func test_mismatchedPhase_earlierTokenDoesNotCommit() async throws {
        // Use two distinct model types so we can give them separate gated backends.
        let firstBackend = GatedLoadBackend()
        let secondBackend = GatedLoadBackend()

        let coordinator = ModelLifecycleCoordinator()
        coordinator.registerBackendFactory { type in
            switch type {
            case .gguf: firstBackend
            case .foundation: secondBackend
            case .mlx: nil
            default: nil
            }
        }

        let taskA = Task {
            try await coordinator.loadModel(from: makeModelInfo(name: "A", modelType: .gguf))
        }
        await firstBackend.waitUntilLoadStarted()

        let taskB = Task {
            try await coordinator.loadModel(from: makeModelInfo(name: "B", modelType: .foundation))
        }
        await secondBackend.waitUntilLoadStarted()

        // A finishes first — its token no longer matches latestRequestedLoadToken.
        await firstBackend.releaseSuccess()
        _ = try? await taskA.value

        XCTAssertFalse(coordinator.isModelLoaded,
                       "Token A no longer matches latestRequestedLoadToken — commit must be suppressed")

        // B finishes — its token does match.
        await secondBackend.releaseSuccess()
        try await taskB.value

        XCTAssertTrue(coordinator.isModelLoaded,
                      "Token B is the latest; its commit must succeed")
    }

    // MARK: - 5. Unload resets phase

    /// After a successful load, calling `unloadModel()` must reset `isModelLoaded`
    /// to `false` and clear `activeBackendName` and `activeModelName`.
    ///
    /// Sabotage: if `unloadModel()` omits resetting `isModelLoaded`, the assert below
    /// would catch it. Equally, skipping `activeBackendName = nil` or `activeModelName = nil`
    /// exposes those nil checks.
    func test_unloadModel_resetsPhaseToIdle() async throws {
        let (coordinator, backend) = makeCoordinatorAndGate()

        let task = Task { try await coordinator.loadModel(from: makeModelInfo()) }
        await backend.waitUntilLoadStarted()
        await backend.releaseSuccess()
        try await task.value

        XCTAssertTrue(coordinator.isModelLoaded, "Pre-condition: model must be loaded before unload")

        coordinator.unloadModel()

        XCTAssertFalse(coordinator.isModelLoaded, "isModelLoaded must be false after unloadModel()")
        XCTAssertNil(coordinator.activeBackendName, "activeBackendName must be nil after unloadModel()")
        XCTAssertNil(coordinator.activeModelName, "activeModelName must be nil after unloadModel()")
    }

    // MARK: - 6. Failure on stale request is classified as stale

    /// When request A fails after request B has already started, A's failure
    /// is stale — it must not flip the model state (which is now owned by B).
    ///
    /// Concretely: if A fails while B is in-flight, `isModelLoaded` must remain
    /// `false` (since B hasn't committed yet), and `modelLoadProgress` must still
    /// read as `0.0` (B's progress), not `nil` (A's idle reset).
    ///
    /// Sabotage: if `finishLoadAttemptWithFailure` ignores the `isStale` guard and
    /// always resets the phase to `.idle`, B's in-flight progress (0.0) would be
    /// cleared to `nil`.
    func test_staleFailure_doesNotResetPhase() async throws {
        let firstBackend = GatedLoadBackend()
        let secondBackend = GatedLoadBackend()

        let coordinator = ModelLifecycleCoordinator()
        coordinator.registerBackendFactory { type in
            switch type {
            case .gguf: firstBackend
            case .foundation: secondBackend
            case .mlx: nil
            default: nil
            }
        }

        // Start A.
        let taskA = Task {
            try? await coordinator.loadModel(from: makeModelInfo(name: "A", modelType: .gguf))
        }
        await firstBackend.waitUntilLoadStarted()

        // Start B — supersedes A.
        let taskB = Task {
            try await coordinator.loadModel(from: makeModelInfo(name: "B", modelType: .foundation))
        }
        await secondBackend.waitUntilLoadStarted()

        // modelLoadProgress should be 0.0 (B started, seed value).
        XCTAssertEqual(coordinator.modelLoadProgress, 0.0,
                       "B's load should have seeded modelLoadProgress to 0.0")

        // A fails — stale failure must not reset phase or wipe B's progress.
        await firstBackend.releaseFailure(CoordinatorTestError.plannedFailure)
        await taskA.value

        XCTAssertEqual(coordinator.modelLoadProgress, 0.0,
                       "A's stale failure must not clear B's in-flight modelLoadProgress")
        XCTAssertFalse(coordinator.isModelLoaded,
                       "B has not committed yet — model must not be loaded")

        // Let B succeed.
        await secondBackend.releaseSuccess()
        try await taskB.value

        XCTAssertTrue(coordinator.isModelLoaded, "B must commit after A's stale failure was ignored")
    }

    // MARK: - 7. Failure on current request resets to idle

    /// When the current (non-stale) request fails, the coordinator must return
    /// to an idle state: `isModelLoaded = false` and `modelLoadProgress = nil`.
    ///
    /// Sabotage: if `finishLoadAttemptWithFailure` doesn't reset `loadPhase` to
    /// `.idle`, the coordinator would remain in `.loading` forever, blocking
    /// subsequent loads from committing.
    func test_currentRequestFailure_resetsToIdle() async throws {
        let (coordinator, backend) = makeCoordinatorAndGate()

        let task = Task {
            try await coordinator.loadModel(from: makeModelInfo())
        }
        await backend.waitUntilLoadStarted()

        XCTAssertEqual(coordinator.modelLoadProgress, 0.0,
                       "modelLoadProgress should be 0.0 once load begins")

        await backend.releaseFailure(CoordinatorTestError.plannedFailure)

        do {
            try await task.value
            XCTFail("Expected load to throw")
        } catch CoordinatorTestError.plannedFailure {
            // expected
        }

        XCTAssertFalse(coordinator.isModelLoaded,
                       "isModelLoaded must remain false after a current-request failure")
        XCTAssertNil(coordinator.modelLoadProgress,
                     "modelLoadProgress must return to nil after a current-request failure")
    }

    // MARK: - 8. Consecutive loads without explicit unload

    /// Starting load B while load A is in-flight (no explicit unload call) must
    /// invalidate A via the `latestRequestedLoadToken` check. When A later
    /// succeeds, it is suppressed; B's eventual success commits normally.
    ///
    /// Sabotage: if `beginLoadRequest` doesn't update `latestRequestedLoadToken`,
    /// both A and B would believe they're the current token and the first to
    /// complete would commit — a race.
    func test_consecutiveLoadsWithoutUnload_onlyLatestCommits() async throws {
        let firstBackend = GatedLoadBackend()
        let secondBackend = GatedLoadBackend()

        let coordinator = ModelLifecycleCoordinator()
        coordinator.registerBackendFactory { type in
            switch type {
            case .gguf: firstBackend
            case .foundation: secondBackend
            case .mlx: nil
            default: nil
            }
        }

        // A starts.
        let taskA = Task {
            try await coordinator.loadModel(from: makeModelInfo(name: "A", modelType: .gguf))
        }
        await firstBackend.waitUntilLoadStarted()

        // B starts while A is still in-flight.
        let taskB = Task {
            try await coordinator.loadModel(from: makeModelInfo(name: "B", modelType: .foundation))
        }
        await secondBackend.waitUntilLoadStarted()

        // A succeeds — but B is now the latest token, so A must be suppressed.
        await firstBackend.releaseSuccess()
        _ = try? await taskA.value

        XCTAssertFalse(coordinator.isModelLoaded,
                       "A must be suppressed when B was started before A's success arrived")

        // B succeeds.
        await secondBackend.releaseSuccess()
        try await taskB.value

        XCTAssertTrue(coordinator.isModelLoaded, "B must commit as the latest-wins request")
        XCTAssertEqual(coordinator.activeBackendName, BackendName.foundation.rawValue,
                       "activeBackendName must reflect B's backend")
    }
}

// MARK: - Test Errors

private enum CoordinatorTestError: Error, Sendable {
    case plannedFailure
}

// MARK: - Gated Load Backend

/// A local-model backend whose `loadModel` is held open by an async gate until
/// the test explicitly releases it with success or failure.
///
/// This lets tests interleave load requests deterministically without sleeping.
private final class GatedLoadBackend: InferenceBackend, @unchecked Sendable {
    // OSAllocatedUnfairLock protects mutable state accessed from both the
    // @MainActor test body and the Task.detached load dispatch inside
    // ModelLifecycleCoordinator, avoiding data races.
    private let stateLock = OSAllocatedUnfairLock(initialState: (isModelLoaded: false, isGenerating: false))

    var isModelLoaded: Bool {
        stateLock.withLock { $0.isModelLoaded }
    }
    var isGenerating: Bool {
        stateLock.withLock { $0.isGenerating }
    }

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    private let gate = LoadGate()

    func waitUntilLoadStarted() async { await gate.waitUntilStarted() }
    func releaseSuccess() async { await gate.releaseSuccess() }
    func releaseFailure(_ error: any Error & Sendable) async { await gate.releaseFailure(error) }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        await gate.markStarted()
        switch await gate.waitForRelease() {
        case .success:
            stateLock.withLock { $0.isModelLoaded = true }
        case .failure(let error):
            throw error
        }
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        return GenerationStream(stream)
    }

    func stopGeneration() {}

    func unloadModel() {
        stateLock.withLock { state in
            state.isModelLoaded = false
            state.isGenerating = false
        }
    }
}

// MARK: - Advisory keep-alive bridge wiring (#1931)

extension ModelLifecycleCoordinatorTests {

    private func makeOllamaEndpoint() -> APIEndpointRecord {
        APIEndpointRecord(
            name: "Local Ollama",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2"
        )
    }

    /// A non-`.never` policy must be bridged into the endpoint backend's
    /// advisory residency horizon at load time.
    ///
    /// Sabotage: deleting the `applyAdvisoryKeepAlive` call in
    /// `loadEndpointBackend` leaves `receivedAdvisoryTimeout == nil` and the
    /// assertion fails.
    func test_loadEndpointBackend_bridgesKeepAlivePolicyIntoAdvisoryResidency() async throws {
        let coordinator = ModelLifecycleCoordinator()
        let spy = AdvisoryEndpointSpyBackend()
        coordinator.registerEndpointBackendFactory { provider in
            provider == .ollama ? spy : nil
        }
        coordinator.keepAlivePolicy = KeepAlivePolicy(idleTimeout: 120)

        try await coordinator.loadEndpointBackend(from: makeOllamaEndpoint())

        XCTAssertTrue(coordinator.isModelLoaded)
        XCTAssertEqual(
            spy.receivedAdvisoryTimeout,
            120,
            "loadEndpointBackend must bridge the owned idleTimeout into the backend's advisory residency"
        )
    }

    /// A `.never` policy (idleTimeout == nil) must still call the bridge but
    /// advise `nil` so the backend keeps its own default residency.
    func test_loadEndpointBackend_neverPolicy_advisesNilTimeout() async throws {
        let coordinator = ModelLifecycleCoordinator()
        let spy = AdvisoryEndpointSpyBackend()
        coordinator.registerEndpointBackendFactory { provider in
            provider == .ollama ? spy : nil
        }
        // .never is the default; assert explicitly for clarity.
        coordinator.keepAlivePolicy = .never

        try await coordinator.loadEndpointBackend(from: makeOllamaEndpoint())

        XCTAssertTrue(spy.didReceiveAdvisoryCall, "The bridge should still be invoked under .never")
        XCTAssertNil(spy.receivedAdvisoryTimeout, "A .never policy advises a nil timeout — no advice given")
    }
}

/// Endpoint backend spy that records the advisory keep-alive timeout it is given.
private final class AdvisoryEndpointSpyBackend:
    InferenceBackend,
    EndpointBackendURLModelConfigurable,
    AdvisoryResidencyConfigurable,
    @unchecked Sendable {

    private(set) var didReceiveAdvisoryCall = false
    private(set) var receivedAdvisoryTimeout: TimeInterval?

    private let stateLock = OSAllocatedUnfairLock(initialState: false)
    var isModelLoaded: Bool { stateLock.withLock { $0 } }
    var isGenerating: Bool { false }

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    func configure(baseURL: URL, modelName: String) {}

    func applyAdvisoryKeepAlive(idleTimeout: TimeInterval?) {
        didReceiveAdvisoryCall = true
        receivedAdvisoryTimeout = idleTimeout
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        stateLock.withLock { $0 = true }
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        GenerationStream(AsyncThrowingStream<GenerationEvent, Error> { $0.finish() })
    }

    func stopGeneration() {}
    func unloadModel() { stateLock.withLock { $0 = false } }
}

// MARK: - LoadGate Actor

/// An actor-based gate that blocks `loadModel` until the test releases it.
private actor LoadGate {
    enum Release: Sendable {
        case success
        case failure(any Error & Sendable)
    }

    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseDecision: Release?
    private var releaseWaiters: [CheckedContinuation<Release, Never>] = []

    func markStarted() {
        didStart = true
        for w in startWaiters { w.resume() }
        startWaiters.removeAll()
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async -> Release {
        if let releaseDecision { return releaseDecision }
        return await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func releaseSuccess() {
        release(.success)
    }

    func releaseFailure(_ error: any Error & Sendable) {
        release(.failure(error))
    }

    private func release(_ decision: Release) {
        guard releaseDecision == nil else { return }
        releaseDecision = decision
        for w in releaseWaiters { w.resume(returning: decision) }
        releaseWaiters.removeAll()
    }
}
