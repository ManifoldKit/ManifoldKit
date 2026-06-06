import Testing
import Foundation
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// E2E test for the memory pressure -> model unload pipeline.
///
/// Wires `MemoryPressureHandler` through `ChatViewModel` to `InferenceService`
/// with a real backend mock, verifying the full chain: pressure level change ->
/// generation stops -> model unloads -> user-facing state updates.
///
/// Uses `MockInferenceBackend` rather than a real ML backend so the test runs
/// without hardware. The DispatchSource-based handler is tested at the unit level;
/// here we set `pressureLevel` directly to simulate OS events deterministically.
@Suite("Memory Pressure Unload E2E")
@MainActor
struct MemoryPressureUnloadE2ETests {

    // MARK: - Helpers

    private let sixteenGB: UInt64 = 16 * 1_024 * 1_024 * 1_024

    /// Builds a fully-wired ChatViewModel with injectable pressure handler and mock backend.
    private func makeViewModel(
        handler: MemoryPressureHandler = MemoryPressureHandler(),
        mock: MockInferenceBackend = MockInferenceBackend()
    ) -> (ChatViewModel, MockInferenceBackend, MemoryPressureHandler) {
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "Mock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: sixteenGB),
            modelStorage: ModelStorageService(),
            memoryPressure: handler
        )
        vm.activeSession = ChatSession(title: "E2E Pressure Test")
        return (vm, mock, handler)
    }

    // MARK: - Full Lifecycle: nominal -> critical -> nominal

    /// Exercises the complete memory pressure lifecycle through the real wiring:
    /// 1. Model is loaded and generation works.
    /// 2. Critical pressure fires -> model unloads, isModelLoaded becomes false,
    ///    error message is shown.
    /// 3. Pressure returns to nominal -> error clears.
    @Test func fullLifecycle_criticalUnloadsThenNominalRecovers() async {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = await makeViewModel(handler: handler)

        // --- Phase 1: Healthy state ---
        #expect(vm.inferenceService.isModelLoaded,
            "Precondition: model should be loaded")
        #expect(vm.errorMessage == nil,
            "Precondition: no error message")
        #expect(vm.memoryPressureLevel == .nominal,
            "Precondition: pressure should be nominal")
        #expect(mock.unloadCallCount == 0)

        // Verify generation works before pressure event.
        mock.tokensToYield = ["Hello"]
        vm.inputText = "Test prompt"
        await vm.sendMessage()
        #expect(vm.errorMessage == nil,
            "Generation should complete without error")
        let assistantMsg = vm.messages.last { $0.role == .assistant }
        #expect(assistantMsg != nil,
            "An assistant message should exist after generation")
        #expect(assistantMsg?.content.contains("Hello") == true,
            "Assistant message should contain the expected token, got: \(assistantMsg?.content ?? "nil")")
        #expect(!(assistantMsg?.content.isEmpty ?? true),
            "Assistant message content should be non-empty")

        // --- Phase 2: Critical pressure fires ---
        handler.pressureLevel = .critical
        vm.handleMemoryPressure()

        #expect(mock.unloadCallCount == 1,
            "unloadModel should be called once at critical pressure")
        #expect(!mock.isModelLoaded,
            "Backend should report model unloaded")
        #expect(!vm.inferenceService.isModelLoaded,
            "InferenceService.isModelLoaded should be false after critical pressure")

        // User-facing error should explain the unload.
        #expect(vm.errorMessage != nil,
            "Error message should be set after critical pressure")
        #expect(
            vm.errorMessage?.contains("critical") == true
            || vm.errorMessage?.contains("unloaded") == true,
            "Error should mention critical pressure or unloading, got: \(vm.errorMessage ?? "nil")"
        )

        // --- Phase 3: Pressure returns to nominal ---
        handler.pressureLevel = .nominal
        vm.handleMemoryPressure()

        #expect(vm.errorMessage == nil,
            "Error message should be cleared when pressure returns to nominal")
        // Model stays unloaded -- the user must reload manually.
        #expect(!vm.inferenceService.isModelLoaded,
            "Model should remain unloaded after pressure clears (manual reload required)")
    }

    // MARK: - Warning Does Not Unload

    /// Warning-level pressure should set an advisory error but NOT unload the model.
    @Test func warningPressure_doesNotUnloadModel() async {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = await makeViewModel(handler: handler)

        handler.pressureLevel = .warning
        vm.handleMemoryPressure()

        #expect(vm.inferenceService.isModelLoaded,
            "Model should remain loaded at warning level")
        #expect(mock.unloadCallCount == 0,
            "unloadModel should NOT be called at warning level")
        #expect(vm.errorMessage != nil,
            "Advisory error message should be set at warning level")
    }

    // MARK: - Critical During Generation

    /// If memory pressure goes critical while generation is in progress,
    /// the model should be unloaded and generation stopped.
    @Test func criticalDuringGeneration_stopsAndUnloads() async throws {
        let slow = SlowMockBackend()
        slow.tokensToYield = (0..<30).map { "tok\($0) " }
        slow.delayPerToken = .milliseconds(50)

        let handler = MemoryPressureHandler()
        let service = InferenceService(backend: slow, name: "SlowMock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: sixteenGB),
            modelStorage: ModelStorageService(),
            memoryPressure: handler
        )
        vm.activeSession = ChatSession(title: "Pressure During Gen")

        // Start a slow generation.
        vm.inputText = "Tell me something long"
        let genTask = Task { @MainActor in
            await vm.sendMessage()
        }

        // Poll until generation begins with a generous deadline. A cold large-model
        // load plus first token can take well over 2s under full-suite load (this
        // suite may run against a real backend in some lanes), so the original 2s
        // window tripped the precondition before generation even started. 60s is a
        // safe upper bound for a cold 8B load; the loop exits the instant
        // `isGenerating` flips, so a fast mock startup pays no extra cost.
        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !vm.isGenerating && ContinuousClock.now < startupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard vm.isGenerating else {
            genTask.cancel()
            await genTask.value
            Issue.record("Precondition failed: generation did not start within 60s")
            return
        }

        // Simulate critical memory pressure mid-generation.
        handler.pressureLevel = .critical
        vm.handleMemoryPressure()

        // Model should be unloaded immediately.
        #expect(!vm.inferenceService.isModelLoaded,
            "Model should be unloaded after critical pressure during generation")

        // Wait for the generation task to finish (it should exit gracefully).
        await genTask.value

        #expect(!vm.isGenerating,
            "Generation should have stopped after critical pressure")
        #expect(vm.errorMessage != nil,
            "Error message should be set after critical pressure during generation")
    }

    // MARK: - Escalation: warning -> critical

    /// Pressure escalating from warning to critical should trigger unload on the
    /// critical transition, not on the initial warning.
    @Test func escalation_warningThenCritical_unloadsOnCritical() async {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = await makeViewModel(handler: handler)

        // Step 1: warning -- no unload.
        handler.pressureLevel = .warning
        vm.handleMemoryPressure()
        #expect(mock.unloadCallCount == 0,
            "No unload at warning level")
        #expect(vm.inferenceService.isModelLoaded,
            "Model should still be loaded at warning")

        // Step 2: escalate to critical -- unload fires.
        handler.pressureLevel = .critical
        vm.handleMemoryPressure()
        #expect(mock.unloadCallCount == 1,
            "unloadModel should fire when escalating to critical")
        #expect(!vm.inferenceService.isModelLoaded,
            "Model should be unloaded after critical escalation")
    }

    // MARK: - Repeated Critical Is Idempotent

    /// Calling handleMemoryPressure twice at critical level should only unload once.
    @Test func repeatedCritical_unloadsOnlyOnce() async {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = await makeViewModel(handler: handler)

        handler.pressureLevel = .critical
        vm.handleMemoryPressure()
        vm.handleMemoryPressure()

        #expect(mock.unloadCallCount == 1,
            "Second critical call should be a no-op (same level guard)")
    }

    // MARK: - memoryPressureLevel Reflects Handler

    /// The view model's `memoryPressureLevel` computed property should always
    /// reflect the handler's current state.
    @Test func memoryPressureLevel_reflectsHandler() async {
        let handler = MemoryPressureHandler()
        let (vm, _, _) = await makeViewModel(handler: handler)

        #expect(vm.memoryPressureLevel == .nominal)

        handler.pressureLevel = .warning
        #expect(vm.memoryPressureLevel == .warning)

        handler.pressureLevel = .critical
        #expect(vm.memoryPressureLevel == .critical)

        handler.pressureLevel = .nominal
        #expect(vm.memoryPressureLevel == .nominal)
    }
}
