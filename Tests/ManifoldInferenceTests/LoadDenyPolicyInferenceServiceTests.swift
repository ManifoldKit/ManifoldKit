import XCTest
import os
@testable import ManifoldInference
import ManifoldTestSupport

/// Verifies that `InferenceService.denyPolicy` — the three-way policy applied when a
/// `ModelLoadPlan` returns a `.deny` verdict — correctly governs the deny path.
///
/// Tests build a plan explicitly via `ModelLoadPlan.compute` with a controlled
/// `Environment` and pass it to `loadModel(from:plan:)` so the test fixtures do not
/// depend on real-device memory.
final class LoadDenyPolicyInferenceServiceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeModel() -> ModelInfo {
        ModelInfo(
            name: "test-model",
            fileName: "fake.gguf",
            url: URL(fileURLWithPath: "/tmp/fake.gguf"),
            fileSize: 4_000_000_000,  // 4 GB, way over the 500 MB fake environment
            modelType: .gguf
        )
    }

    private func makeDenyingPlan(for model: ModelInfo) -> ModelLoadPlan {
        let environment = ModelLoadPlan.Environment(
            availableMemoryBytes: { 500_000_000 },       // 500 MB available
            physicalMemoryBytes: 8_000_000_000
        )
        let plan = ModelLoadPlan.compute(
            for: model,
            requestedContextSize: 2048,
            strategy: .resident,
            environment: environment
        )
        // Precondition: fixture must produce a .deny verdict or the test is meaningless.
        XCTAssertEqual(plan.verdict, .deny,
                       "Fixture must produce a .deny plan; got \(plan.verdict)")
        return plan
    }

    @MainActor
    private func makeService() -> InferenceService {
        let service = InferenceService()
        service.registerBackendFactory { _ in
            let caps = BackendCapabilities(
                supportedParameters: [.temperature],
                maxContextTokens: 2048,
                requiresPromptTemplate: false,
                supportsSystemPrompt: true,
                supportsToolCalling: false,
                supportsStructuredOutput: false,
                cancellationStyle: .cooperative,
                supportsTokenCounting: false,
                memoryStrategy: .resident
            )
            return MockInferenceBackend(capabilities: caps)
        }
        return service
    }

    // MARK: - throwError policy throws on deny plan

    @MainActor
    func test_throwErrorPolicy_denyPlanThrows_memoryInsufficient() async {
        let service = makeService()
        service.denyPolicy = .throwError

        let model = makeModel()
        let plan = makeDenyingPlan(for: model)

        do {
            try await service.loadModel(from: model, plan: plan)
            XCTFail("Expected memoryInsufficient error")
        } catch let error as InferenceError {
            guard case .memoryInsufficient(let required, let available) = error else {
                XCTFail("Expected memoryInsufficient, got \(error)")
                return
            }
            // `required` is the plan's total (resident + KV), not just the file size.
            XCTAssertGreaterThanOrEqual(required, 4_000_000_000)
            XCTAssertEqual(available, 500_000_000)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertFalse(service.isModelLoaded)
    }

    // MARK: - warnOnly policy proceeds

    @MainActor
    func test_warnOnlyPolicy_denyPlanLogs_doesNotThrow() async throws {
        let service = makeService()
        service.denyPolicy = .warnOnly

        let model = makeModel()
        let plan = makeDenyingPlan(for: model)

        try await service.loadModel(from: model, plan: plan)
        XCTAssertTrue(service.isModelLoaded)
    }

    // MARK: - custom policy sees plan

    @MainActor
    func test_customPolicy_denyPlanInvokesHandler() async throws {
        let service = makeService()

        let capturedVerdict = LockedValue<ModelLoadPlan.Verdict?>(nil)
        service.denyPolicy = .custom { plan in
            capturedVerdict.set(plan.verdict)
            // Proceed.
        }

        let model = makeModel()
        let plan = makeDenyingPlan(for: model)

        try await service.loadModel(from: model, plan: plan)
        XCTAssertEqual(capturedVerdict.get(), .deny)
        XCTAssertTrue(service.isModelLoaded)
    }

    // MARK: - custom policy may reject by throwing

    @MainActor
    func test_customPolicy_canThrowToReject() async {
        let service = makeService()

        struct CustomRejection: Error, Equatable {}
        service.denyPolicy = .custom { _ in throw CustomRejection() }

        let model = makeModel()
        let plan = makeDenyingPlan(for: model)

        do {
            try await service.loadModel(from: model, plan: plan)
            XCTFail("Expected CustomRejection")
        } catch is CustomRejection {
            // success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(service.isModelLoaded)
    }

    // MARK: - .allow verdict bypasses policy entirely

    /// With a plan that produces `.allow`, no policy branch fires — even a
    /// custom hook that would reject is never consulted. The backend receives
    /// the plan unmodified (verdict preserved, no reasons appended).
    @MainActor
    func test_allowPlan_customPolicyNotInvoked_planDispatchedUnchanged() async throws {
        let service = InferenceService()
        let capturingBackend = PlanCapturingBackend()
        service.registerBackendFactory { _ in capturingBackend }

        // Custom policy that would throw if invoked.
        struct ShouldNotBeInvoked: Error {}
        let customCalled = LockedValue<Bool>(false)
        service.denyPolicy = .custom { _ in
            customCalled.set(true)
            throw ShouldNotBeInvoked()
        }

        let model = makeModel()
        let plan = makeAllowingPlan(for: model)

        try await service.loadModel(from: model, plan: plan)

        XCTAssertFalse(customCalled.get(), "Custom policy was invoked despite .allow verdict")
        XCTAssertTrue(service.isModelLoaded)

        let received = capturingBackend.lastPlan
        XCTAssertEqual(received?.verdict, .allow)
        // Plan delivered to the backend must be the *original* — not downgraded.
        XCTAssertEqual(received?.outcome.totalEstimatedBytes, plan.outcome.totalEstimatedBytes)
    }

    // MARK: - .warn verdict proceeds and dispatches .warn plan to backend

    /// The `.warn` verdict is an "info" state — load proceeds regardless of
    /// `denyPolicy`, and the backend observes the warning via the plan's
    /// verdict (the only public handle the warning has).
    @MainActor
    func test_warnPlan_loadProceeds_backendReceivesWarnVerdict() async throws {
        let service = InferenceService()
        let capturingBackend = PlanCapturingBackend()
        service.registerBackendFactory { _ in capturingBackend }

        // Even .throwError policy must not fire on a .warn plan.
        service.denyPolicy = .throwError

        let model = makeModel()
        let plan = makeWarningPlan(for: model)

        try await service.loadModel(from: model, plan: plan)

        XCTAssertTrue(service.isModelLoaded)
        let received = capturingBackend.lastPlan
        XCTAssertEqual(received?.verdict, .warn,
                       "Backend must observe the .warn verdict so it can surface the warning itself")
    }

    /// `.deny` + `.warnOnly` downgrades the plan to `.warn` before dispatching
    /// to the backend (backends assert `plan.verdict != .deny`). This is the
    /// observable difference between a native-.warn plan and a downgraded one:
    /// the backend still sees `.warn`, but the service's `isModelLoaded`
    /// flips after proceeding despite insufficient memory.
    @MainActor
    func test_denyPlan_warnOnlyPolicy_dispatchesDowngradedWarnVerdict() async throws {
        let service = InferenceService()
        let capturingBackend = PlanCapturingBackend()
        service.registerBackendFactory { _ in capturingBackend }
        service.denyPolicy = .warnOnly

        let model = makeModel()
        let plan = makeDenyingPlan(for: model)

        try await service.loadModel(from: model, plan: plan)

        // The coordinator promises to downgrade .deny → .warn before handing
        // the plan to the backend. This is the invariant backends rely on.
        XCTAssertEqual(capturingBackend.lastPlan?.verdict, .warn,
                       "warnOnly policy must downgrade .deny to .warn before dispatch")
    }

    // MARK: - Fixtures for allow/warn

    private func makeAllowingPlan(for model: ModelInfo) -> ModelLoadPlan {
        let environment = ModelLoadPlan.Environment(
            availableMemoryBytes: { 64_000_000_000 },  // 64 GB — plenty
            physicalMemoryBytes: 128_000_000_000
        )
        let plan = ModelLoadPlan.compute(
            for: model,
            requestedContextSize: 2048,
            strategy: .mappable,
            environment: environment
        )
        XCTAssertEqual(plan.verdict, .allow,
                       "Fixture must produce an .allow plan; got \(plan.verdict)")
        return plan
    }

    /// Builds an inputs fixture guaranteed to produce `.warn`.
    ///
    /// Headroom 0.0 + no resident + kv total == available → above the 85%
    /// allow threshold but within the available ceiling → `.warn`.
    private func makeWarningPlan(for model: ModelInfo) -> ModelLoadPlan {
        let inputs = ModelLoadPlan.Inputs(
            modelFileSize: 0,
            memoryStrategy: .external,
            requestedContextSize: 1_000_000,
            trainedContextLength: 1_000_000,
            kvBytesPerToken: 1,
            availableMemoryBytes: 1_000_000,
            physicalMemoryBytes: 16_000_000_000,
            absoluteContextCeiling: 128_000_000,
            headroomFraction: 0.0
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.verdict, .warn,
                       "Fixture must produce a .warn plan; got \(plan.verdict)")
        // Keep the fixture coupled to the real model identifier so test logs
        // show the same modelName as other cases.
        _ = model
        return plan
    }
}

// MARK: - Plan-capturing backend

/// Mock backend that records the `ModelLoadPlan` it receives on `loadModel`.
/// Used to verify the coordinator dispatches the right verdict (pre-downgrade
/// for `.allow`/`.warn`, downgraded for `.deny` + `.warnOnly`).
private final class PlanCapturingBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = false
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 2048,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: false,
        supportsStructuredOutput: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false,
        memoryStrategy: .mappable
    )

    // OSAllocatedUnfairLock is the async-safe variant; NSLock is not allowed
    // inside Swift-6 async contexts.
    private let state = OSAllocatedUnfairLock<ModelLoadPlan?>(initialState: nil)

    var lastPlan: ModelLoadPlan? {
        state.withLock { $0 }
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        state.withLock { $0 = plan }
        isModelLoaded = true
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        throw InferenceError.inferenceFailure("unused in these tests")
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }
    func resetConversation() {}
}

// MARK: - Test helpers

/// Simple thread-safe box for capturing values inside @Sendable closures.
private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func set(_ new: T) { lock.lock(); defer { lock.unlock() }; value = new }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
