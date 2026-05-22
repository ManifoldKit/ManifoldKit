#if MLX
import CoreImage
import Foundation
// Direct `MLX.Memory.cacheLimit` / `MLX.Memory.clearCache()` calls from this
// file are forbidden — the cache is process-global and must be coordinated
// across multiple MLX backends via `MLXResourceArbiter.shared`. See
// `MLX/MLXResourceArbiter.swift` for the rationale.
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import Tokenizers // required by the #huggingFaceTokenizerLoader macro expansion
import os
import ManifoldInference

/// MLX Swift inference backend for safetensors/MLX-format models.
///
/// Uses the high-level `MLXLLM` API from `mlx-swift-lm`. Models are loaded
/// from local directories containing `config.json` + `.safetensors` weights,
/// or downloaded from HuggingFace by model ID.
///
/// Requires real Apple Silicon hardware — does not work in iOS Simulator.
public final class MLXBackend: InferenceBackend, @unchecked Sendable {

    // MARK: - Logging

    private static let logger = Logger(
        subsystem: ManifoldConfiguration.shared.logSubsystem,
        category: "inference"
    )

    // MARK: - State

    private var _isModelLoaded = false
    private var _isGenerating = false

    public private(set) var isModelLoaded: Bool {
        get { withStateLock { _isModelLoaded } }
        set { withStateLock { _isModelLoaded = newValue } }
    }

    public private(set) var isGenerating: Bool {
        get { withStateLock { _isGenerating } }
        set { withStateLock { _isGenerating = newValue } }
    }

    // MARK: - Locking

    private let stateLock = NSLock()

    @discardableResult
    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    // MARK: - Capabilities

    public var capabilities: BackendCapabilities {
        withStateLock {
            // The manifest is populated at loadModel-time from config.json's
            // `max_position_embeddings`. Until a load completes (or for
            // injected test doubles that bypass loadModel), fall back to the
            // historical conservative 8k default rather than a manifest the
            // probe never produced.
            let ctxTokens = Int32(_manifest?.contextWindow ?? 8192)
            return BackendCapabilities(
                supportedParameters: [
                    .temperature, .topP, .topK, .repeatPenalty,
                    .minP, .repetitionPenalty, .presencePenalty, .frequencyPenalty,
                ],
                maxContextTokens: ctxTokens,
                requiresPromptTemplate: false,
                supportsSystemPrompt: true,
                supportsToolCalling: true,
                supportsStructuredOutput: false,
                supportsNativeJSONMode: false,
                cancellationStyle: .cooperative,
                supportsTokenCounting: true,
                memoryStrategy: .resident,
                maxOutputTokens: 4096,
                supportsStreaming: true,
                isRemote: false,
                supportsKVCachePersistence: enableKVCacheReuse,
                supportsThinking: true,
                supportsVision: _supportsVision,
                sharesMLXProcessResources: true
            )
        }
    }

    // MARK: - Private

    /// Access only under `stateLock`.
    private var _modelContainer: (any MLXModelContainerProtocol)?
    /// Access only under `stateLock`.
    private var _generationTask: Task<Void, Never>?
    /// Access only under `stateLock`.
    private var _conversationHistory: [(role: String, content: String)] = []
    /// The tool-call dialect detected for the currently loaded model.
    /// Set by `loadModel(from:plan:)` via `MLXToolDialect.detect(at:)`.
    /// Access only under `stateLock`.
    private var _dialect: MLXToolDialect = .unknown
    /// Tool-aware conversation history, set by `setToolAwareHistory(_:)`.
    /// When non-nil this supersedes `_conversationHistory` for message building.
    /// Access only under `stateLock`.
    private var _toolAwareHistory: [ToolAwareHistoryEntry]?
    /// Structured conversation history, including image parts for VLM turns.
    /// Access only under `stateLock`.
    private var _structuredHistory: [StructuredMessage]?
    /// Thinking-marker pair auto-detected from the loaded model's
    /// `tokenizer_config.json` chat template. `nil` when the model is not
    /// loaded, the chat template is missing, or no known marker pair was
    /// found in the template. `GenerationConfig.thinkingMarkers` always
    /// overrides this — see the generate path below.
    /// Access only under `stateLock`.
    private var _autoDetectedThinkingMarkers: ThinkingMarkers?
    /// Prompt KV-cache reuse state. Access only under `stateLock`.
    private var _promptCacheState = MLXPromptCacheCoordinator.State()
    /// Whether the currently loaded model/config is eligible for prompt-cache reuse.
    /// Access only under `stateLock`.
    private var _kvCacheReuseEligible = false
    /// Tracks whether a real MLX model load initialized the runtime in this process.
    /// Access only under `stateLock`.
    private var _hasInitializedRuntime = false
    /// Stable per-instance identity used by `MLXResourceArbiter` to track
    /// which backend holds which slice of the process-global cache budget.
    /// Generated once at init; never changes.
    private let backendID: MLXResourceArbiter.BackendID = UUID()
    /// Whether the currently loaded MLX model accepts image inputs.
    /// Access only under `stateLock`.
    private var _supportsVision = false

    /// Manifest produced at ``loadModel(from:plan:)`` time from the model's
    /// `config.json` and `tokenizer_config.json`. Drives ``capabilities``'s
    /// `maxContextTokens` once populated; falls back to `8192` until then.
    /// Access only under `stateLock`.
    private var _manifest: ModelManifest?

    /// Public accessor for the manifest captured at the most recent successful
    /// load. Returns `nil` before any load and after ``unloadModel()``. Used by
    /// ``ContextWindowManager`` and the conformance harness — see
    /// `BackendCapabilitiesContractTests`.
    public var manifest: ModelManifest? { withStateLock { _manifest } }

    /// Backend tuning knobs (KV cache quantization, prefill batch size).
    /// Applied at every ``generate`` call's ``GenerateParameters`` construction.
    /// Access only under `stateLock`. MLX honours `kvCacheQuantization` and
    /// `prefillBatchSize`; `flashAttention` is silently ignored (MLX's SDPA
    /// path is always flash-attention-shaped).
    private var _loadOptions: BackendLoadOptions = .default

    /// Test-only read-side accessor that snapshots `_loadOptions` under the
    /// state lock. Lets plumbing tests assert the setter persisted the value
    /// without needing a real model load.
    var loadOptionsForTesting: BackendLoadOptions { withStateLock { _loadOptions } }

    // MARK: - Load Progress

    /// Guarded by `stateLock`. Set by `setLoadProgressHandler(_:)` before each load.
    ///
    /// `loadModelContainer(from: URL)` in `mlx-swift-lm` provides no granular progress hook
    /// on local directory loads — the progress handler overload is only available for download
    /// paths. We emit synthetic bookends (0.0 before, 1.0 after) so `InferenceService` can
    /// distinguish "load started" from "load complete" rather than showing a flat 0% spinner.
    private var _loadProgressHandler: (@Sendable (Double) async -> Void)?

    // MARK: - Configuration

    /// Policy controlling MLX's GPU buffer cache size. See `MLXCachePolicy`.
    /// Defaults to `.auto`, which picks a sensible value based on device RAM.
    public let cachePolicy: MLXCachePolicy
    /// Safe-first rollout flag for prompt KV-cache reuse.
    public let enableKVCacheReuse: Bool

    // MARK: - Test seams

    /// Invoked in place of `Task.yield()` at every
    /// `yieldEveryNTokens`-th token during generation. Tests use this to count
    /// yield occurrences deterministically without timing assertions.
    ///
    /// `nil` in production — the real cooperative yield runs instead.
    nonisolated(unsafe) static var _yieldHookForTesting: (@Sendable () async -> Void)?

    // MARK: - Init

    public init(
        cachePolicy: MLXCachePolicy = .auto,
        enableKVCacheReuse: Bool = false
    ) {
        self.cachePolicy = cachePolicy
        self.enableKVCacheReuse = enableKVCacheReuse
    }

    /// Forwards to `MLXGenerationDriver.resolveThinkingMarkers(...)`.
    ///
    /// The canonical implementation moved into the driver as part of Phase
    /// 2.5/β. This forwarder is retained for source-compat with
    /// `MLXBackendHelpersTests`, which exercises marker-resolution policy
    /// through the backend's surface.
    static func resolveThinkingMarkers(
        config: GenerationConfig,
        autoDetected: ThinkingMarkers?
    ) -> ThinkingMarkers? {
        MLXGenerationDriver.resolveThinkingMarkers(
            config: config,
            autoDetected: autoDetected
        )
    }

    // MARK: - Model Lifecycle

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        assert(plan.verdict != .deny,
               "ModelLoadPlan was denied; callers must check verdict before invoking backend")
        // MLX reads context sizing from the model container; `plan` is informational
        // here and kept for consistency with the protocol. Future work could honour
        // `plan.effectiveContextSize` to cap generation length.
        unloadModel()

        // Preflight: refuse non-LM architectures up front so a CLIP/SigLIP/Whisper
        // snapshot can't crash MLX mid-generation or silently produce garbage tokens.
        // We read config.json directly rather than letting mlx-swift-lm attempt the
        // load and fail — mlx-swift-lm's own error message ("unsupportedModelType")
        // surfaces through `modelLoadFailed(underlying:)` and hides the root cause
        // from the UI. Throwing `.unsupportedModelArchitecture` here makes the reason
        // explicit and lets `ChatError` map it to `.selectModel`.
        try MLXModelProbe.validateArchitecture(at: url)

        let progressHandler = withStateLock { _loadProgressHandler }

        // Signal "load started". The `mlx-swift-lm` local-directory API has no granular
        // progress hook, so we emit a 0.0 bookend here and a 1.0 bookend after the load
        // completes. This gives InferenceService enough signal to animate a progress
        // indicator rather than showing a flat 0% spinner for the full load duration.
        await progressHandler?(0.0)

        do {
            // Probe once; both the vision flag and the factory-routing decision
            // consume the same result so config.json is read only once here.
            let probedCapabilities: ModelCapabilities?
            do {
                probedCapabilities = try ModelCapabilityProbe.probe(modelDirectory: url)
            } catch {
                Log.inference.info(
                    "MLX capability probe failed for \(url.lastPathComponent, privacy: .public); continuing with conservative vision defaults (\(error.localizedDescription, privacy: .public))"
                )
                probedCapabilities = nil
            }
            let supportsVision = BackendVisionCapability.mlxSupportsImageInput(probedCapabilities: probedCapabilities)
            let routeThroughVLMFactory = MLXModelProbe.requiresVLMFactory(at: url, precomputedCapabilities: probedCapabilities)
            // Load from a local directory containing config.json + .safetensors.
            // We dispatch directly to either `LLMModelFactory.shared` or
            // `VLMModelFactory.shared` rather than calling the registry-iterating
            // free function `loadModelContainer(from:using:)`. Reason: the MoE
            // Gemma 4 decoder lives only on the VLM side in mlx-swift-lm 3.31.3
            // (`Libraries/MLXVLM/Models/Gemma4.swift`), so the registry walk
            // would otherwise hand the 26B `gemma4` model to the dense
            // `Gemma4Text.swift` LLM path and fail with "Unhandled keys
            // [experts, router, …]". See issue #752. Dense Gemma 4 variants
            // stay on the LLM factory unless the model also declares
            // `vision_config` or `text_config.enable_moe_block`.
            //
            // `#huggingFaceTokenizerLoader()` (from MLXHuggingFace) adapts
            // swift-transformers' `AutoTokenizer` to the `TokenizerLoader`
            // protocol both factories accept.
            let container: ModelContainer
            if routeThroughVLMFactory {
                Self.logger.info("MLX routing via VLMModelFactory (MoE / VLM-only architecture)")
                container = try await VLMModelFactory.shared.loadContainer(
                    from: url,
                    using: #huggingFaceTokenizerLoader()
                )
            } else {
                container = try await LLMModelFactory.shared.loadContainer(
                    from: url,
                    using: #huggingFaceTokenizerLoader()
                )
            }
            let detectedDialect = MLXToolDialect.detect(at: url)
            let detectedThinkingMarkers = MLXModelProbe.detectThinkingMarkers(at: url)
            let producedManifest = MLXModelProbe.produceManifest(
                at: url,
                detectedThinkingMarkers: detectedThinkingMarkers,
                supportsVision: supportsVision
            )
            let kvCacheReuseEligible = enableKVCacheReuse && !routeThroughVLMFactory
            withStateLock {
                _modelContainer = container
                _dialect = detectedDialect
                _autoDetectedThinkingMarkers = detectedThinkingMarkers
                _supportsVision = supportsVision
                _manifest = producedManifest
                _promptCacheState.invalidate()
                _kvCacheReuseEligible = kvCacheReuseEligible
                _hasInitializedRuntime = true
            }
            // Apply the cache policy after loadModelContainer succeeds. Doing
            // this *after* the load (rather than before) keeps it inside the
            // implicit "MLX runtime is initialized" window — touching MLX's
            // Memory namespace before the runtime is up trips a metallib
            // load error in environments without Xcode-compiled shaders
            // (e.g. `swift test`). The cost is that the load itself runs
            // under whatever cacheLimit was previously in effect — usually
            // mlx-swift's own default on a fresh process, which is fine.
            //
            // The cache is process-global; route through `MLXResourceArbiter`
            // so multi-backend hosts (chat + embeddings, A/B comparisons)
            // accumulate per-instance claims rather than overwriting each
            // other's `cacheLimit`.
            let cacheBytes = cachePolicy.resolvedBytes()
            await MLXResourceArbiter.shared.claim(
                backendID: backendID,
                requestedCacheBytes: cacheBytes
            )
            Self.logger.info("MLX cache claim registered: \(cacheBytes / (1024 * 1024)) MB (policy: \(String(describing: self.cachePolicy)))")
            isModelLoaded = true
            // Signal load complete before returning so InferenceService sees 1.0
            // before it clears the handler and flips isModelLoaded.
            await progressHandler?(1.0)
            Self.logger.info("MLX backend loaded model from \(url.lastPathComponent)")
        } catch {
            Self.logger.error("MLX model load failed: \(error)")
            throw InferenceError.modelLoadFailed(underlying: error)
        }
    }

    // MARK: - Generation

    /// Generates a token stream from the loaded MLX model.
    ///
    /// - Important: Generation is dispatched to `@MainActor` because `ModelContainer.generate()`
    ///   in `mlx-swift-lm` must be called on the main thread (the MLX GPU scheduler is not
    ///   thread-safe). This means long responses will occupy the main event loop. The effect
    ///   is mitigated by the relatively short context windows used for on-device inference.
    ///   If a future version of `mlx-swift-lm` supports a background-thread generate API,
    ///   remove the `@MainActor` annotation from the inner `Task`.
    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        // Single critical section: validate, flip `_isGenerating`, and
        // snapshot every input the driver needs. The driver runs without
        // touching backend state — so once we leave the lock, the driver call
        // is decoupled from `setLoadOptions` / `setConversationHistory` /
        // `setToolAwareHistory` racing in.
        let snapshot: GenerationCallSnapshot = try withStateLock {
            guard _isModelLoaded, let container = _modelContainer else {
                throw InferenceError.inferenceFailure("No model loaded")
            }
            guard !_isGenerating else {
                throw InferenceError.alreadyGenerating
            }
            _isGenerating = true
            return GenerationCallSnapshot(
                container: container,
                loadOptions: _loadOptions,
                conversationHistory: _conversationHistory,
                toolAwareHistory: _toolAwareHistory,
                structuredHistory: _structuredHistory,
                dialect: _dialect,
                autoDetectedMarkers: _autoDetectedThinkingMarkers,
                kvCacheReuseEligible: _kvCacheReuseEligible,
                pendingSnapshotTask: _promptCacheState.pendingSnapshotTask
            )
        }
        Self.logger.debug("MLX generate started")

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        let generationStream = GenerationStream(stream)

        let task = Task { @MainActor [weak self, generationStream] in
            defer {
                Self.logger.debug("MLX generate finished")
            }

            do {
                let driver = MLXGenerationDriver()
                let result = try await driver.generate(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    config: config,
                    loadOptions: snapshot.loadOptions,
                    container: snapshot.container,
                    conversationHistory: snapshot.conversationHistory,
                    toolAwareHistory: snapshot.toolAwareHistory,
                    structuredHistory: snapshot.structuredHistory,
                    dialect: snapshot.dialect,
                    autoDetectedMarkers: snapshot.autoDetectedMarkers,
                    kvCacheReuseEligible: snapshot.kvCacheReuseEligible,
                    pendingSnapshotTask: snapshot.pendingSnapshotTask,
                    // Closure re-reads the snapshot AFTER the driver awaits
                    // `pendingSnapshotTask`, so we see the value the prior turn's
                    // snapshot task wrote rather than the nil we'd have captured here.
                    currentSnapshot: { [weak self] in
                        self?.withStateLock { self?._promptCacheState.snapshot } ?? nil
                    },
                    generationStream: generationStream,
                    continuation: continuation,
                    yieldHook: MLXBackend._yieldHookForTesting
                )

                if let self {
                    self.withStateLock { self._isGenerating = false }
                }
                generationStream.setPhase(.done)
                if let self, let snapshotInputs = result.snapshotInputs {
                    self.scheduleSnapshotCaptureLocked(
                        cache: snapshotInputs.cache,
                        promptTokenIds: snapshotInputs.promptTokenIds
                    )
                }
                continuation.finish()
            } catch {
                if let self {
                    self.withStateLock { self._isGenerating = false }
                }
                if !Task.isCancelled {
                    Self.logger.error("MLX generation error: \(error)")
                    generationStream.setPhase(.failed(error.localizedDescription))
                    continuation.finish(throwing: error)
                    return
                }
                generationStream.setPhase(.done)
                continuation.finish()
            }
        }

        withStateLock { self._generationTask = task }

        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                task.cancel()
            }
        }

        return generationStream
    }

    /// Coherent per-call snapshot of every piece of backend state the driver
    /// reads. Captured under `stateLock` so the driver's view stays consistent
    /// even if a `set*History` / `setLoadOptions` call lands mid-stream.
    private struct GenerationCallSnapshot {
        let container: any MLXModelContainerProtocol
        let loadOptions: BackendLoadOptions
        let conversationHistory: [(role: String, content: String)]
        let toolAwareHistory: [ToolAwareHistoryEntry]?
        let structuredHistory: [StructuredMessage]?
        let dialect: MLXToolDialect
        let autoDetectedMarkers: ThinkingMarkers?
        let kvCacheReuseEligible: Bool
        let pendingSnapshotTask: Task<Void, Never>?
    }

    /// Schedules an off-main capture of the prompt KV cache for next-turn reuse.
    ///
    /// The capture itself runs `@MainActor` because every MLX call inside
    /// `MLXPromptCacheCoordinator.capturePromptCacheSnapshot` shares the
    /// single-threaded GPU scheduler with `ModelContainer.generate`. A monotonic
    /// write token guards against stale snapshots overwriting a newer turn's
    /// cache state if the next `generate()` call has already invalidated this
    /// lineage.
    @MainActor
    private func scheduleSnapshotCaptureLocked(
        cache: MLXPromptCache,
        promptTokenIds: [Int]
    ) {
        withStateLock {
            _promptCacheState.writeToken &+= 1
            let snapshotWriteToken = _promptCacheState.writeToken
            let snapshotTask = MLXPromptCacheCoordinator.makeSnapshotCaptureTask(
                cache: cache,
                promptTokenIds: promptTokenIds,
                writeToken: snapshotWriteToken
            ) { [weak self] token, snapshot in
                guard let self else { return }
                self.withStateLock {
                    guard self._promptCacheState.writeToken == token else { return }
                    self._promptCacheState.snapshot = snapshot
                    self._promptCacheState.pendingSnapshotTask = nil
                }
            }
            _promptCacheState.pendingSnapshotTask = snapshotTask
        }
    }

    // MARK: - Testing

    /// Injects a mock container so unit tests can exercise the generation path
    /// without loading real model weights. Call this before `generate()`.
    ///
    /// Not part of the public API — visible to `ManifoldBackendsTests` via `@testable import`.
    func _inject(
        _ container: any MLXModelContainerProtocol,
        supportsVision: Bool = false,
        dialect: MLXToolDialect = .unknown
    ) {
        withStateLock {
            _modelContainer = container
            _isModelLoaded = true
            _supportsVision = supportsVision
            _dialect = dialect
            _promptCacheState.invalidate()
            _kvCacheReuseEligible = enableKVCacheReuse
            _hasInitializedRuntime = false
        }
    }

    func _hasPromptCacheSnapshotForTesting() -> Bool {
        withStateLock { _promptCacheState.hasSnapshotOrPending }
    }

    func _isPromptCacheSnapshotReadyForTesting() -> Bool {
        withStateLock { _promptCacheState.isSnapshotReady }
    }

    /// Test-only seam: forces the auto-detected thinking markers to a specific
    /// value, simulating what the load path would have read from
    /// `tokenizer_config.json`. Tests use this to verify that
    /// `config.thinkingMarkers` correctly overrides auto-detection without
    /// having to stage a real model directory.
    func _injectAutoDetectedThinkingMarkers(_ markers: ThinkingMarkers?) {
        withStateLock { _autoDetectedThinkingMarkers = markers }
    }

    // MARK: - Control

    public func stopGeneration() {
        withStateLock {
            _generationTask?.cancel()
            _generationTask = nil
        }
    }

    public func unloadModel() {
        stopGeneration()
        // Only touch MLX's Memory namespace after a real model load has
        // initialized the runtime in this process. Injected test doubles do not
        // compile the metallib, so releasing the arbiter claim after
        // `_inject(...)` would trip the same failure this guard exists to
        // avoid (the arbiter calls `Memory.clearCache()` on the last release).
        let hadInitializedRuntime: Bool = withStateLock {
            let had = _hasInitializedRuntime
            _modelContainer = nil
            _isModelLoaded = false
            _isGenerating = false
            _conversationHistory = []
            _toolAwareHistory = nil
            _structuredHistory = nil
            _dialect = .unknown
            _autoDetectedThinkingMarkers = nil
            _supportsVision = false
            _manifest = nil
            _promptCacheState.invalidate()
            _kvCacheReuseEligible = false
            _hasInitializedRuntime = false
            return had
        }
        if hadInitializedRuntime {
            // Fire-and-forget: the protocol contract for `unloadModel()` is
            // synchronous, but cache eviction does not need to block teardown.
            // The arbiter clears `MLX.Memory` only on the last release; while
            // sibling MLX backends are still loaded, this preserves their
            // pooled buffers — that's the whole point of routing through the
            // arbiter rather than calling `Memory.clearCache()` directly.
            let id = backendID
            Task { await MLXResourceArbiter.shared.release(backendID: id) }
        }
        Self.logger.info("MLX backend unloaded")
    }
}

// MARK: - ConversationHistoryReceiver

extension MLXBackend: ConversationHistoryReceiver {
    public func setConversationHistory(_ history: [(role: String, content: String)]) {
        withStateLock {
            _conversationHistory = history
            // Clear any previously stored tool-aware history so the simpler path takes
            // effect when the orchestrator calls the non-tool-aware setter.
            _toolAwareHistory = nil
        }
    }
}

extension MLXBackend {
    public func resetConversation() {
        withStateLock {
            _conversationHistory = []
            _toolAwareHistory = nil
            _structuredHistory = nil
            _promptCacheState.invalidate()
        }
    }

    /// Evicts pooled Metal GPU buffers that may contain KV-cache residue from
    /// prior inference turns.
    ///
    /// MLX does not expose an API to explicitly zero Metal `MTLBuffer` contents
    /// after the fact; the best available measure is to evict all pooled buffers
    /// (`MLX.Memory.clearCache()` under the hood, routed through
    /// ``MLXResourceArbiter/clearAll()``) so they are returned to the OS rather
    /// than reused by the next request. The prompt-cache state is also
    /// invalidated so the next ``generate(_:config:)`` call starts fresh.
    ///
    /// **Note**: this provides an eviction guarantee, NOT a zero guarantee. Any
    /// residue in currently-active Metal allocations (e.g. mid-stream) is
    /// not affected.
    public func secureWipe() {
        let hasRuntime = withStateLock { () -> Bool in
            _promptCacheState.invalidate()
            return _hasInitializedRuntime
        }
        #if MLX
        if hasRuntime {
            // `secureWipe` is an explicit eviction request — the docstring
            // promises the pooled buffers are returned to the OS. Because the
            // pool is process-global, partial scrubbing isn't possible: route
            // through `clearAll` so the arbiter drops accounting state too,
            // and surviving sibling backends will re-claim on their next
            // load.
            Task { await MLXResourceArbiter.shared.clearAll() }
        }
        #endif
    }
}

// MARK: - StructuredHistoryReceiver

extension MLXBackend: StructuredHistoryReceiver {
    public func setStructuredHistory(_ messages: [StructuredMessage]) {
        withStateLock { _structuredHistory = messages }
    }
}

// MARK: - ToolCallingHistoryReceiver

extension MLXBackend: ToolCallingHistoryReceiver {
    /// Stores a tool-aware conversation history for the next `generate()` call.
    ///
    /// When set, this supersedes the plain `(role, content)` history provided
    /// via `setConversationHistory(_:)`. The entries are encoded into the
    /// Qwen 2.5 text format (or plain content for `.unknown` dialects) before
    /// being passed to the MLX generate path.
    public func setToolAwareHistory(_ messages: [ToolAwareHistoryEntry]) {
        withStateLock { _toolAwareHistory = messages }
    }
}

// MARK: - LoadProgressReporting

extension MLXBackend: LoadProgressReporting {
    /// Installs a synthetic-bookend progress handler. Because `mlx-swift-lm`'s local-directory
    /// load path exposes no granular progress, the handler receives `0.0` when the load begins
    /// and `1.0` when it completes successfully. This is enough for `InferenceService` to show
    /// a non-zero progress indicator rather than a flat 0% spinner.
    public func setLoadProgressHandler(_ handler: (@Sendable (Double) async -> Void)?) {
        withStateLock { _loadProgressHandler = handler }
    }

    /// Installs backend tuning knobs (KV cache quantization, prefill batch size)
    /// applied at every ``generate(prompt:systemPrompt:config:)``
    /// ``GenerateParameters`` construction.
    ///
    /// MLX honours `kvCacheQuantization` (mapped to `kvBits = nil/8/4`) and
    /// `prefillBatchSize` (mapped to `prefillStepSize`). The `flashAttention`
    /// field is silently ignored — MLX's SDPA path is always
    /// flash-attention-shaped.
    ///
    /// Defaults use Q8 KV cache and backend-default prefill batching. Per the
    /// BCK API shape, `BackendLoadOptions` is named "load" because llama.cpp
    /// wires these into `ctxParams` at context-creation time. MLX could in
    /// principle change them per-generation; the API stays load-time-shaped to
    /// keep both backends symmetric.
    public func setLoadOptions(_ options: BackendLoadOptions) {
        withStateLock { _loadOptions = options }
    }
}
#endif
