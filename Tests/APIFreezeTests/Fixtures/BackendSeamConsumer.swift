import Foundation
// The backend seam spans three visibility tiers:
//   - public API in ManifoldInference / ManifoldHardware / ManifoldContract,
//   - @_spi(BackendInternals) symbols published for the companion family
//     packages (manifold-mlx / manifold-llama, #1749),
//   - the @_spi(BackendInternals) ChatViewModel initializer in ManifoldUI.
// The SPI imports below are themselves part of the freeze: if a symbol's
// SPI group is renamed or the symbol is demoted to `package`/`internal`,
// this file stops compiling.
@_spi(BackendInternals) import ManifoldContract
@_spi(BackendInternals) import ManifoldHardware
@_spi(BackendInternals) import ManifoldUI
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport

/// Compile-time freeze of the **cross-repo backend seam** — the exact surface
/// the companion family packages (manifold-mlx / manifold-llama, #1749)
/// compile against once `ManifoldMLX`/`ManifoldLlama` leave this repo.
///
/// **Compilation IS the assertion** (same mechanism as
/// ``PublicSurfaceConsumer``): if any frozen symbol is removed, renamed,
/// has its signature drift, or loses its `public`/`@_spi(BackendInternals)`
/// visibility, this file fails to compile and CI fails. A change that breaks
/// this file would break the companion packages on their next pin-bump —
/// treat it as a `feat!:`-grade seam change, update the companions in
/// lockstep, and only then update this fixture.
///
/// Frozen surface (v0.48 go/no-go gate, plan §3 B3):
///
/// 1. **Contract kernel** (`ManifoldContract`): `InferenceBackend` witness
///    shapes, `GenerationEvent` cases + payloads, `GenerationConfig`,
///    `BackendCapabilities` (full init frozen in `PublicSurfaceConsumer`),
///    `GenerationStream`, `LocalInferenceAdapter` witness shapes.
/// 2. **Registration** (`ManifoldInference`): `BackendRegistrar`,
///    `InferenceService.registerBackendFactory`, `declareSupport(for:)`,
///    `registeredBackendSnapshot()`, `compatibility(for:)`.
/// 3. **Hardware seam** (`ManifoldHardware`): `ModelType`, `EnabledBackends`,
///    `ModelCompatibilityResult`, `ModelLoadPlan` (+ `Inputs`/`Outcome`/
///    `Verdict`), `APIProvider` registration cases.
/// 4. **`@_spi(BackendInternals)`**: `MemoryPressureHandler`,
///    `HeuristicTokenizer`, `ChatViewModel.init(...memoryPressure:...)`,
///    `GGUFKVCacheEstimator` + `GGUFKVCacheParameters` (manifold-llama
///    derives prefill-footprint expectations from the estimator, C2).
/// 5. **Test-support seam** (`ManifoldTestSupport` /
///    `ManifoldBackendTestKit` products): `HardwareRequirements` here;
///    `BackendContractChecks` / `LocalBackendContractRunner` shapes are
///    pinned by `scripts/split-proof.sh`, which compiles the real family
///    conformance suites against the products out-of-package.
@MainActor
enum BackendSeamConsumer {

    static func consumeSeam() {
        consumeContractKernelWitnesses()
        consumeGenerationStreamShape()
        consumeRegistrationSurface()
        consumeHardwareSeamTypes()
        consumeModelLoadPlan()
        consumeBackendInternalsSPI()
        consumeHardwareRequirements()
    }

    // MARK: - 1. Contract kernel — InferenceBackend witness shapes

    /// A conforming class pins every protocol requirement's exact shape.
    /// Adding a requirement *without* a default implementation, or changing
    /// any existing witness signature, fails this conformance.
    private final class SeamFrozenBackend: InferenceBackend, @unchecked Sendable {
        var isModelLoaded: Bool { false }
        var isGenerating: Bool { false }
        var capabilities: BackendCapabilities { BackendCapabilities() }
        var manifest: ModelManifest? { nil }
        func loadModel(from url: URL, plan: ModelLoadPlan) async throws {}
        func generate(
            prompt: String,
            systemPrompt: String?,
            config: GenerationConfig
        ) throws -> GenerationStream {
            let (stream, continuation) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
            continuation.finish()
            return GenerationStream(stream)
        }
        func stopGeneration() {}
        func unloadModel() {}
        func resetConversation() {}
        func secureWipe() {}
    }

    /// `LocalInferenceAdapter` is the composition root both family generation
    /// drivers conform to (`MLXGenerationDriver`, `LlamaGenerationDriver`).
    private struct SeamFrozenAdapter: LocalInferenceAdapter {
        var adapterName: String { "freeze.seam" }
        var toolCallShape: any LocalToolCallShape { InlineXMLToolCallMarkers() }
        var thinkingMarkerStrategy: LocalThinkingMarkerStrategy { .eagerWhenMarkersPresent }
        var declaredCapabilities: BackendCapabilities { BackendCapabilities() }
    }

    private static func consumeContractKernelWitnesses() {
        let backend: any InferenceBackend = SeamFrozenBackend()
        _ = backend.isModelLoaded
        _ = backend.capabilities

        let adapter: any LocalInferenceAdapter = SeamFrozenAdapter()
        _ = adapter.adapterName
        _ = adapter.toolCallShape.shapeName
        _ = adapter.declaredCapabilities

        // GenerationConfig: default init + the mutable fields family drivers
        // read. (Full BackendCapabilities init is frozen in
        // PublicSurfaceConsumer.consumeBackendCapabilities().)
        var config = GenerationConfig()
        config.grammar = nil
        _ = config
    }

    /// Exhaustive switch over `GenerationEvent`. Family backends *produce*
    /// these events; the runtime consumes them with exhaustive switches.
    /// Case removal, rename, payload-shape change, **and case addition** all
    /// fail here — an added case is source-breaking for every consumer that
    /// switches exhaustively, so the freeze flagging it is intentional.
    private static func consumeGenerationEventCases(_ event: GenerationEvent) {
        switch event {
        case .prefillProgress(let tokensProcessed, let tokensTotal, let tokensPerSecond):
            _ = (tokensProcessed, tokensTotal, tokensPerSecond)
        case .token(let text):
            _ = text
        case .usage(let usage):
            _ = (usage.promptTokens, usage.completionTokens)
        case .toolCall(let call):
            _ = call
        case .toolCallStart(callId: let callId, name: let name):
            _ = (callId, name)
        case .toolCallArgumentsDelta(callId: let callId, textDelta: let delta):
            _ = (callId, delta)
        case .thinkingToken(let text):
            _ = text
        case .thinkingCompleted:
            break
        case .thinkingSignature(let signature):
            _ = signature
        case .toolIterationLimitExceeded(iterations: let iterations):
            _ = iterations
        case .toolResult(let result):
            _ = result
        case .toolProgress(let progress):
            _ = progress
        case .kvCacheReuse(promptTokensReused: let reused):
            _ = reused
        case .throttleDiagnostic(reason: let reason):
            _ = reason
        case .toolCallParseFailed(rawBody: let rawBody):
            _ = rawBody
        case .toolCallTruncated(rawBody: let rawBody):
            _ = rawBody
        case .toolDispatchStarted(callId: let callId, name: let name, attempt: let attempt):
            _ = (callId, name, attempt)
        case .toolCallApproved(callId: let callId):
            _ = callId
        case .toolDispatchCompleted(callId: let callId, durationMilliseconds: let ms, errorKind: let kind):
            _ = (callId, ms, kind)
        case .handoffRequested(let handoff):
            _ = handoff
        case .generationCompleted(let completion):
            _ = completion.reason
        }
    }

    private static func consumeGenerationStreamShape() {
        let (stream, continuation) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        continuation.yield(.token("seam"))
        continuation.finish()
        // Both init forms family backends use: bare and idle-timeout.
        let generation = GenerationStream(stream)
        _ = generation.events
        _ = generation.idleTimeout
        consumeGenerationEventCases(.token("seam"))

        let (timedStream, timedContinuation) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        timedContinuation.finish()
        _ = GenerationStream(timedStream, idleTimeout: .seconds(30))
    }

    // MARK: - 2. Registration surface

    /// The exact conformance shape every companion registrar declares
    /// (`MLXBackends`, `LlamaBackends` post-split).
    private enum SeamFrozenRegistrar: BackendRegistrar {
        @MainActor static func register(with service: InferenceService) {
            // Exhaustive ModelType switch: registrars route on this enum, so
            // an added case must surface here as a compile error — every
            // companion's factory switch breaks the same way.
            service.registerBackendFactory { (modelType: ModelType) -> (any InferenceBackend)? in
                switch modelType {
                case .gguf, .mlx, .foundation:
                    return nil
                }
            }
            service.declareSupport(for: ModelType.gguf)
        }
    }

    private static func consumeRegistrationSurface() {
        let service = InferenceService()
        SeamFrozenRegistrar.register(with: service)

        // The public factory typealias is itself seam surface.
        let factory: BackendFactory = { _ in nil }
        service.registerBackendFactory(factory)

        service.declareSupport(for: ModelType.foundation)
        service.declareSupport(for: APIProvider.ollama)

        let snapshot: EnabledBackends = service.registeredBackendSnapshot()
        _ = snapshot.localModelTypes
        _ = snapshot.cloudProviders
        _ = snapshot.supportsGGUF
        _ = snapshot.supportsMLX
        _ = snapshot.supportsFoundation
        _ = snapshot.supportsLocalInference
        _ = snapshot.isEmpty

        let byType: ModelCompatibilityResult = service.compatibility(for: ModelType.mlx)
        _ = byType.isSupported
        _ = byType.unavailableReason
        let _: ModelCompatibilityResult = service.compatibility(for: APIProvider.ollama)
    }

    // MARK: - 3. Hardware seam types

    private static func consumeHardwareSeamTypes() {
        // ModelType: the routing currency between registrars and the registry.
        let _: ModelType = .gguf
        let _: ModelType = .mlx
        let _: ModelType = .foundation

        let _: EnabledBackends = EnabledBackends(
            localModelTypes: [.gguf],
            cloudProviders: [.ollama]
        )

        let _: ModelCompatibilityResult = .supported
        let unsupported: ModelCompatibilityResult = .unsupported(reason: "frozen")
        _ = unsupported.isSupported
        _ = unsupported.unavailableReason
    }

    private static func consumeModelLoadPlan() {
        // Full Inputs init — backends receive a plan computed from these.
        let inputs = ModelLoadPlan.Inputs(
            modelFileSize: 1,
            memoryStrategy: .mappable,
            requestedContextSize: 4096,
            trainedContextLength: 8192,
            kvBytesPerToken: 1,
            availableMemoryBytes: 1,
            physicalMemoryBytes: 1,
            absoluteContextCeiling: 8192,
            headroomFraction: 0.8,
            appOverheadBytes: 0,
            measuredBytesPerToken: nil
        )
        let outcome = ModelLoadPlan.Outcome(
            effectiveContextSize: 4096,
            estimatedResidentBytes: 1,
            estimatedKVBytes: 1,
            totalEstimatedBytes: 2,
            verdict: .allow,
            reasons: []
        )
        let plan = ModelLoadPlan(inputs: inputs, outcome: outcome)
        _ = plan.effectiveContextSize
        _ = plan.verdict
        _ = plan.reasons
        _ = ModelLoadPlan.compute(inputs: inputs)

        let _: ModelLoadPlan.Verdict = .allow
        let _: ModelLoadPlan.Verdict = .warn
        let _: ModelLoadPlan.Verdict = .deny
    }

    // MARK: - 4. @_spi(BackendInternals)

    /// Lifetime anchor for the pressure-callback registration shape.
    private final class CallbackOwner {}

    private static func consumeBackendInternalsSPI() {
        // MemoryPressureHandler — LlamaBackend registers a synchronous
        // pressure callback to abort the decode loop (LlamaBackend.swift).
        // Function *references* (not calls) pin the signatures without
        // installing a real GCD memory-pressure source in the test process.
        let handler = MemoryPressureHandler(queueLabel: "com.manifoldkit.api-freeze.seam")
        let _: MemoryPressureLevel = handler.pressureLevel
        let _: () -> Void = handler.startMonitoring
        let _: () -> Void = handler.stopMonitoring
        let _: (AnyObject, @escaping @Sendable (MemoryPressureLevel) -> Void) -> Void =
            handler.addPressureCallback
        let _: (AnyObject) -> Void = handler.removeCallback

        let owner = CallbackOwner()
        handler.addPressureCallback(for: owner) { (_: MemoryPressureLevel) in }
        handler.removeCallback(for: owner)

        let _: MemoryPressureLevel = .nominal
        let _: MemoryPressureLevel = .warning
        let _: MemoryPressureLevel = .critical

        // HeuristicTokenizer — LlamaBackend's chars/4 fallback when no
        // vocabulary is loaded (instance + stateless static form).
        let tokenizer = HeuristicTokenizer()
        let _: any TokenizerProvider = tokenizer
        _ = tokenizer.tokenCount("abcd")
        _ = HeuristicTokenizer.tokenCount("abcd")

        // GGUFKVCacheEstimator — manifold-llama's prefill-footprint
        // integration tests derive their expected KV bytes/token from this
        // estimator (C2 seam addition; previously an inlined constant).
        let _: UInt64 = GGUFKVCacheEstimator.defaultBytesPerElement
        let _: UInt64 = GGUFKVCacheEstimator.legacyFallbackBytesPerToken
        let kvParameters = GGUFKVCacheParameters(
            blockCount: 32,
            embeddingLength: 4_096,
            attentionHeadCount: 32,
            attentionHeadCountKV: 8,
            attentionKeyLength: nil,
            attentionValueLength: nil
        )
        let _: UInt64? = GGUFKVCacheEstimator.estimateBytesPerToken(
            from: kvParameters,
            bytesPerElement: 2
        )

        // ChatViewModel SPI initializer — the injected MemoryPressureHandler
        // is itself SPI, so the full init signature lives behind the same
        // SPI group. A *reference* to the initializer pins every parameter
        // label and type without constructing the (storage-touching) view
        // model inside the freeze test.
        typealias SeamChatViewModelInit = (
            InferenceService,
            DeviceCapabilityService,
            ModelStorageService,
            MemoryPressureHandler,
            UIToolApprovalGate?,
            UserDefaults,
            ConversationRuntime?
        ) -> ChatViewModel
        let _: SeamChatViewModelInit = ChatViewModel.init(
            inferenceService:deviceCapability:modelStorage:memoryPressure:toolApprovalGate:userDefaults:conversationRuntime:
        )
    }

    // MARK: - 5. ManifoldTestSupport seam

    private static func consumeHardwareRequirements() {
        // Family test suites gate on these statics (XCTSkipUnless).
        _ = HardwareRequirements.isAppleSilicon
        _ = HardwareRequirements.isPhysicalDevice
        _ = HardwareRequirements.hasMetalDevice
        _ = HardwareRequirements.hasFoundationModels
    }
}
