#if MLX
import CoreImage
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import MLXRandom
import MLXHuggingFace
import Tokenizers
import os
import BaseChatInference

/// MLX Swift inference backend for safetensors/MLX-format models.
///
/// Uses the high-level `MLXLLM` API from `mlx-swift-lm`. Models are loaded
/// from local directories containing `config.json` + `.safetensors` weights,
/// or downloaded from HuggingFace by model ID.
///
/// Requires real Apple Silicon hardware — does not work in iOS Simulator.
public final class MLXBackend: InferenceBackend, @unchecked Sendable {

    private struct CachedLayerState {
        let cacheTypeName: String
        let offset: Int
        let state: [MLXArray]
        let metaState: [String]
    }

    private struct PromptCacheSnapshot {
        let promptTokens: [Int]
        let layers: [CachedLayerState]
    }

    // MARK: - Logging

    private static let logger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
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
            BackendCapabilities(
                supportedParameters: [.temperature, .topP, .repeatPenalty],
                maxContextTokens: 8192,
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
                supportsVision: _supportsVision
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
    /// Cached prompt KV state for longest-common-prefix reuse on the next turn.
    /// Access only under `stateLock`.
    private var _promptCacheSnapshot: PromptCacheSnapshot?
    /// Snapshot capture still materializing after the previous turn finished.
    /// Access only under `stateLock`.
    private var _pendingPromptCacheSnapshotTask: Task<Void, Never>?
    /// Monotonic token used to invalidate stale post-finish snapshot writes.
    /// Access only under `stateLock`.
    private var _promptCacheWriteToken: UInt64 = 0
    /// Whether the currently loaded model/config is eligible for prompt-cache reuse.
    /// Access only under `stateLock`.
    private var _kvCacheReuseEligible = false
    /// Tracks whether a real MLX model load initialized the runtime in this process.
    /// Access only under `stateLock`.
    private var _hasInitializedRuntime = false
    /// Whether the currently loaded MLX model accepts image inputs.
    /// Access only under `stateLock`.
    private var _supportsVision = false

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

    /// Invoked in place of `Task.sleep(for: .microseconds(50))` at every
    /// `yieldEveryNTokens`-th token during generation. Tests use this to count
    /// yield occurrences deterministically without timing assertions.
    ///
    /// `nil` in production — the real microsecond sleep runs instead.
    nonisolated(unsafe) static var _yieldHookForTesting: (@Sendable () async -> Void)?

    // MARK: - Init

    public init(
        cachePolicy: MLXCachePolicy = .auto,
        enableKVCacheReuse: Bool = false
    ) {
        self.cachePolicy = cachePolicy
        self.enableKVCacheReuse = enableKVCacheReuse
    }

    // MARK: - Architecture Allowlist

    /// Canonical `model_type` values that `mlx-swift-lm`'s `LLMTypeRegistry.shared`
    /// can serve as chat/instruct LMs. Anything outside this set (or the
    /// VLM-specific set below) — CLIP, SigLIP, Whisper, BERT embeddings, etc. —
    /// is refused at
    /// load time via `InferenceError.unsupportedModelArchitecture`.
    ///
    /// Sourced from `LLMTypeRegistry.shared` in mlx-swift-lm
    /// (`Libraries/MLXLLM/LLMModelFactory.swift`). When mlx-swift-lm adds a new
    /// LM architecture, update this list to match so the preflight doesn't reject
    /// a freshly supported model.
    static let supportedLMArchitectures: Set<String> = [
        "mistral", "llama", "phi", "phi3", "phimoe",
        "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n", "gemma4",
        "qwen2", "qwen3", "qwen3_moe", "qwen3_next",
        "qwen3_5", "qwen3_5_moe", "qwen3_5_text",
        "minicpm", "starcoder2", "cohere", "openelm", "internlm2",
        "deepseek_v3", "granite", "granitemoehybrid",
        "mimo", "mimo_v2_flash", "minimax",
        "glm4", "glm4_moe", "glm4_moe_lite",
        "acereason", "falcon_h1", "bitnet", "smollm3",
        "ernie4_5", "lfm2", "lfm2_moe",
        "baichuan_m1", "exaone4", "gpt_oss",
        "lille-130m", "olmoe", "olmo2", "olmo3",
        "bailing_moe", "nanochat", "nemotron_h",
        "afmoe", "jamba_3b", "mistral3", "apertus",
    ]

    static let supportedVLMArchitectures: Set<String> = [
        "paligemma", "qwen2_vl", "qwen2_5_vl", "qwen3_vl",
        "qwen3_5", "qwen3_5_moe", "idefics3", "gemma3", "gemma4",
        "smolvlm", "fastvlm", "llava_qwen2", "pixtral", "mistral3",
        "lfm2_vl", "lfm2-vl", "glm_ocr",
    ]

    private static let normalizedSupportedArchitectures: Set<String> =
        Set((supportedLMArchitectures.union(supportedVLMArchitectures)).map(normalizeArchitectureKey))

    private static func normalizeArchitectureKey(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// Reads `config.json` at `url` and throws
    /// `InferenceError.unsupportedModelArchitecture` if the declared `model_type`
    /// is not a chat/instruct LM. If `config.json` is missing or unreadable the
    /// check is a no-op — mlx-swift-lm's own load path will then surface the
    /// real error (missing weights, malformed directory, etc.).
    static func validateArchitecture(at url: URL) throws {
        let configURL = url.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Missing / malformed config.json: let the MLX load path produce the
            // real diagnostic rather than masking it with a false architecture error.
            return
        }

        let modelType = (json["model_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedModelType = normalizeArchitectureKey(modelType)
        if !normalizedModelType.isEmpty,
           normalizedSupportedArchitectures.contains(normalizedModelType) {
            return
        }

        // Some HF repos omit model_type but include an `architectures` array
        // (e.g. ["LlamaForCausalLM"]). Accept the load if any entry's snake_case
        // prefix matches the allowlist — this keeps older snapshots working.
        if let archs = json["architectures"] as? [String] {
            for arch in archs {
                let normalized = normalizeArchitectureKey(arch)
                if Self.normalizedSupportedArchitectures.contains(where: { normalized.hasPrefix($0) }) {
                    return
                }
            }
        }

        let reported = modelType.isEmpty ? (json["architectures"] as? [String])?.joined(separator: ",") ?? "unknown" : modelType
        throw InferenceError.unsupportedModelArchitecture(reported)
    }

    // MARK: - Factory Routing

    /// Returns `true` when the model at `url` must load through the VLM factory.
    ///
    /// This covers both explicit multimodal models (`vision_config`) and the
    /// Gemma 4 MoE path that only exists behind `VLMModelFactory` today.
    ///
    /// Falls back to `false` (LLM factory) when config.json is missing/unreadable —
    /// matches the same conservative default used by `validateArchitecture`. Dense
    /// Gemma 4 models intentionally stay on the LLM factory so we don't pay the
    /// memory cost of resident vision-tower weights.
    static func requiresVLMFactory(at url: URL) -> Bool {
        requiresVLMFactory(at: url, precomputedCapabilities: nil)
    }

    /// Variant that accepts pre-computed capabilities to avoid re-reading
    /// `config.json` when the caller already ran ``ModelCapabilityProbe``.
    static func requiresVLMFactory(
        at url: URL,
        precomputedCapabilities capabilities: ModelCapabilities?
    ) -> Bool {
        // Fast path: vision was already detected by the caller's probe run.
        if let capabilities {
            if capabilities.supportsVision { return true }
        } else {
            do {
                if try ModelCapabilityProbe.probe(modelDirectory: url).supportsVision {
                    return true
                }
            } catch {
                Log.inference.info(
                    "MLX capability probe failed for \(url.lastPathComponent, privacy: .public); falling back to config.json routing (\(error.localizedDescription, privacy: .public))"
                )
            }
        }
        // MoE fallback: Gemma 4 26B ships `text_config.enable_moe_block = true`
        // and its MoE decoder only exists in the VLM factory today.
        let configURL = url.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let textConfig = json["text_config"] as? [String: Any],
           textConfig["enable_moe_block"] as? Bool == true {
            return true
        }
        return false
    }

    private static func longestCommonPrefixLength(_ lhs: [Int], _ rhs: [Int]) -> Int {
        zip(lhs, rhs).prefix(while: { $0 == $1 }).count
    }

    private func invalidatePromptCacheLocked() {
        _pendingPromptCacheSnapshotTask?.cancel()
        _pendingPromptCacheSnapshotTask = nil
        _promptCacheSnapshot = nil
        _promptCacheWriteToken &+= 1
    }

    private static func isSupportedPromptCache(_ caches: [any KVCache]) -> Bool {
        !caches.isEmpty && caches.allSatisfy { $0 is KVCacheSimple }
    }

    private static func chatRole(for role: String) -> Chat.Message.Role {
        switch role {
        case "assistant": .assistant
        case "system": .system
        case "tool": .tool
        default: .user
        }
    }

    private static func userInputImage(from data: Data, mimeType: String) throws -> UserInput.Image {
        guard let image = CIImage(data: data) else {
            throw InferenceError.inferenceFailure(
                "Unsupported image attachment format (\(mimeType))."
            )
        }
        return .ciImage(image)
    }

    private static func imageInputs(from parts: [MessagePart]) throws -> [UserInput.Image] {
        try parts.compactMap { part in
            guard case let .image(data, mimeType) = part else { return nil }
            return try userInputImage(from: data, mimeType: mimeType)
        }
    }

    private static func plainChatMessages(
        history: [StructuredMessage],
        systemPrompt: String?
    ) throws -> [Chat.Message]? {
        let containsImages = history.contains { message in
            message.parts.contains { part in
                if case .image = part { return true }
                return false
            }
        }
        guard containsImages else { return nil }

        var messages: [Chat.Message] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(.system(systemPrompt))
        }
        for message in history {
            messages.append(
                Chat.Message(
                    role: chatRole(for: message.role),
                    content: message.textContent,
                    images: try imageInputs(from: message.parts)
                )
            )
        }
        return messages
    }

    private static func toolAwareChatMessages(
        structuredHistory: [StructuredMessage],
        toolAwareHistory: [ToolAwareHistoryEntry],
        systemPrompt: String?,
        dialect: MLXToolDialect
    ) throws -> [Chat.Message]? {
        guard structuredHistory.contains(where: { message in
            message.parts.contains { part in
                if case .image = part { return true }
                return false
            }
        }) else {
            return nil
        }

        var messages: [Chat.Message] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(.system(systemPrompt))
        }

        let structuredImageParts = try structuredHistory.map { try imageInputs(from: $0.parts) }
        for (index, entry) in toolAwareHistory.enumerated() {
            let encoded = encodeToolAwareEntryAsText(entry, dialect: dialect)
            let role = encoded["role"] ?? entry.role
            let content = encoded["content"] ?? entry.content
            let images = index < structuredImageParts.count ? structuredImageParts[index] : []
            messages.append(
                Chat.Message(
                    role: chatRole(for: role),
                    content: content,
                    images: images
                )
            )
        }

        if toolAwareHistory.count < structuredHistory.count {
            for (offset, structuredMessage) in structuredHistory.dropFirst(toolAwareHistory.count).enumerated() {
                let images = structuredImageParts[toolAwareHistory.count + offset]
                messages.append(
                    Chat.Message(
                        role: chatRole(for: structuredMessage.role),
                        content: structuredMessage.textContent,
                        images: images
                    )
                )
            }
        }

        return messages
    }

    /// Captures prompt-only KV state for the next turn.
    ///
    /// Contract assumptions taken from the currently pinned `mlx-swift-lm`:
    /// 1. `LanguageModel.prepare(_:cache:windowSize:)` consumes any cached prefix
    ///    from the front of the prepared prompt and only evaluates the remaining
    ///    suffix, so restored caches must be paired with the uncached prompt tail.
    /// 2. `KVCacheSimple.copy()/state/metaState/trim(_:)` are sufficient to clone
    ///    and shrink prompt-only state safely for text-only models.
    /// 3. Future `mlx-swift-lm` bumps must rerun the MLX KV-cache integration and
    ///    performance suite before this contract is trusted unchanged.
    ///
    /// Marked `@MainActor` because every MLX call here (`copy()`, `eval`,
    /// `state` slicing, `trim`) shares the same single-threaded GPU scheduler
    /// as `ModelContainer.generate()`; running off-main risks racy crashes /
    /// cache corruption.
    @MainActor
    private static func capturePromptCacheSnapshot(
        from cache: MLXPromptCache,
        promptTokens: [Int]
    ) -> PromptCacheSnapshot? {
        guard !promptTokens.isEmpty, isSupportedPromptCache(cache.value) else {
            return nil
        }
        // Early-exit if the surrounding generation task was cancelled — `copy()`
        // and `eval` materialise full prompt-prefix tensors per layer, which is
        // expensive enough to be worth skipping when a reset/unload already
        // invalidated the snapshot we'd be writing.
        if Task.isCancelled { return nil }

        var layers: [CachedLayerState] = []
        layers.reserveCapacity(cache.value.count)
        for original in cache.value {
            if Task.isCancelled { return nil }
            guard original.offset >= promptTokens.count else {
                return nil
            }

            if original.state.isEmpty {
                layers.append(
                    CachedLayerState(
                        cacheTypeName: String(describing: type(of: original)),
                        offset: promptTokens.count,
                        state: [],
                        metaState: original.metaState
                    )
                )
                continue
            }

            let copy = original.copy()
            eval([copy])

            let excess = copy.offset - promptTokens.count
            if excess > 0 {
                guard copy.isTrimmable, copy.trim(excess) == excess else {
                    return nil
                }
            }

            let state = copy.state.map { $0[.ellipsis] }
            eval(state)
            layers.append(
                CachedLayerState(
                    cacheTypeName: String(describing: type(of: copy)),
                    offset: copy.offset,
                    state: state,
                    metaState: copy.metaState
                )
            )
        }
        return PromptCacheSnapshot(promptTokens: promptTokens, layers: layers)
    }

    private static func restorePromptCache(
        _ snapshot: PromptCacheSnapshot,
        into cache: MLXPromptCache,
        reusedPromptTokenCount: Int
    ) -> Bool {
        guard reusedPromptTokenCount > 0,
              cache.value.count == snapshot.layers.count,
              isSupportedPromptCache(cache.value) else {
            return false
        }

        for (index, layer) in snapshot.layers.enumerated() {
            var target = cache.value[index]
            guard String(describing: type(of: target)) == layer.cacheTypeName else {
                return false
            }
            if layer.state.isEmpty {
                guard let target = target as? KVCacheSimple else { return false }
                target.offset = layer.offset
                target.metaState = layer.metaState
            } else {
                target.state = layer.state.map { $0[.ellipsis] }
                target.metaState = layer.metaState
            }

            guard target.offset >= reusedPromptTokenCount else { return false }
            let excess = target.offset - reusedPromptTokenCount
            if excess > 0 {
                guard target.isTrimmable, target.trim(excess) == excess else {
                    return false
                }
            }
        }

        eval(cache.value)
        return true
    }

    // MARK: - Thinking-Marker Auto-Discovery

    /// Reads `tokenizer_config.json` inside `url` and returns the best-matching
    /// thinking-marker preset for the chat template it declares.
    ///
    /// Best-effort: a missing or unreadable `tokenizer_config.json`, or one
    /// without a `chat_template` field, returns `nil`. The MLX tokenizer object
    /// in `mlx-swift-lm` exposes the chat template through Hugging Face's
    /// swift-transformers, but reaching it requires opening a `ModelContainer`
    /// session — reading the on-disk JSON directly is faster and avoids
    /// tying up the GPU during the load.
    ///
    /// - Parameter url: The model directory URL (same one passed to
    ///   `MLXBackend.loadModel(from:plan:)`).
    /// - Returns: The auto-detected ``ThinkingMarkers`` or `nil` if no known
    ///   marker pair is present in the template.
    static func detectThinkingMarkers(at url: URL) -> ThinkingMarkers? {
        let configURL = url.appendingPathComponent("tokenizer_config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Missing / unreadable tokenizer_config.json is expected for some
            // model layouts (older snapshots, partial downloads). Don't warn —
            // callers explicitly opt out of thinking parsing when this is nil.
            return nil
        }

        // `chat_template` is a single string for most HF tokenizers, but a
        // small number of repos ship an array of `{name, template}` entries
        // (multi-template configs). When that happens, sniff the first entry
        // whose name is `default` (or the first entry overall).
        let templateString: String? = {
            if let s = json["chat_template"] as? String { return s }
            if let arr = json["chat_template"] as? [[String: Any]] {
                if let def = arr.first(where: { ($0["name"] as? String)?.lowercased() == "default" }),
                   let s = def["template"] as? String {
                    return s
                }
                if let s = arr.first?["template"] as? String { return s }
            }
            return nil
        }()
        guard let template = templateString else { return nil }
        return ThinkingMarkers.fromChatTemplate(template)
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
        try Self.validateArchitecture(at: url)

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
            let supportsVision = probedCapabilities?.supportsVision ?? false
            let routeThroughVLMFactory = Self.requiresVLMFactory(at: url, precomputedCapabilities: probedCapabilities)
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
            let detectedThinkingMarkers = Self.detectThinkingMarkers(at: url)
            let kvCacheReuseEligible = enableKVCacheReuse && !routeThroughVLMFactory
            withStateLock {
                _modelContainer = container
                _dialect = detectedDialect
                _autoDetectedThinkingMarkers = detectedThinkingMarkers
                _supportsVision = supportsVision
                invalidatePromptCacheLocked()
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
            let cacheBytes = cachePolicy.resolvedBytes()
            Memory.cacheLimit = cacheBytes
            Self.logger.info("MLX cache limit set to \(cacheBytes / (1024 * 1024)) MB (policy: \(String(describing: self.cachePolicy)))")
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
        let (
            modelContainer,
            pendingSnapshotTask,
            kvCacheReuseEligible
        ): (
            any MLXModelContainerProtocol,
            Task<Void, Never>?,
            Bool
        ) = try withStateLock {
            guard _isModelLoaded, let container = _modelContainer else {
                throw InferenceError.inferenceFailure("No model loaded")
            }
            guard !_isGenerating else {
                throw InferenceError.alreadyGenerating
            }
            _isGenerating = true
            return (container, _pendingPromptCacheSnapshotTask, _kvCacheReuseEligible)
        }
        Self.logger.debug("MLX generate started")

        // Seed the MLX global RandomState before constructing GenerateParameters so the
        // sampler's per-instance `RandomState()` (initialised from the default state)
        // produces a deterministic token stream. `nil` skips seeding entirely — the
        // process keeps whatever entropy MLX last picked up.
        if let seed = config.seed {
            MLXRandom.seed(seed)
        }

        // Honour `config.minP` and `config.repetitionPenalty` when set; fall back to the
        // upstream defaults / `repeatPenalty` for callers that haven't migrated to the
        // explicit knobs yet.
        let generateConfig = GenerateParameters(
            temperature: config.temperature,
            topP: config.topP,
            topK: Int(config.topK ?? 0),
            minP: config.minP ?? 0.0,
            repetitionPenalty: config.repetitionPenalty ?? config.repeatPenalty
        )

        // Build messages in chat format, using full conversation history when available
        // so multi-turn exchanges retain context. Falls back to the bare prompt when
        // setConversationHistory has not been called (e.g. direct unit-test calls).
        let (conversationHistory, toolAwareHistory, structuredHistory, dialect, autoDetectedMarkers) = withStateLock {
            (_conversationHistory, _toolAwareHistory, _structuredHistory, _dialect, _autoDetectedThinkingMarkers)
        }

        // For Qwen 2.5: serialize tool definitions into a <tools>…</tools> block
        // appended to the system message content. This is the standard Qwen chat
        // template mechanism for exposing tools to the model.
        let effectiveSystemPrompt: String? = {
            guard !config.tools.isEmpty, dialect == .qwen25 else {
                return systemPrompt
            }
            let toolObjects: [[String: Any]] = config.tools.map { tool -> [String: Any] in
                var function_: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description,
                ]
                if let paramsData = try? JSONEncoder().encode(tool.parameters),
                   let paramsObj = try? JSONSerialization.jsonObject(with: paramsData) {
                    function_["parameters"] = paramsObj
                } else {
                    function_["parameters"] = ["type": "object", "properties": [String: Any]()]
                }
                return ["type": "function", "function": function_]
            }
            let toolsJSON: String
            if let data = try? JSONSerialization.data(withJSONObject: toolObjects, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                toolsJSON = str
            } else {
                toolsJSON = "[]"
            }
            let toolBlock = "\n\n# Tools\n\nYou may call one or more functions to assist with the user query. Don't make assumptions about what values to plug into functions. Here are the available tools:\n\n<tools>\n\(toolsJSON)\n</tools>\n\nFor each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags as follows:\n<tool_call>\n{\"name\": <function-name>, \"arguments\": <args-json-object>}\n</tool_call>"
            let base = systemPrompt ?? ""
            return base + toolBlock
        }()

        let chatMessages: [Chat.Message]? =
            if let structuredHistory, !structuredHistory.isEmpty {
                if let toolAwareHistory, !toolAwareHistory.isEmpty {
                    try Self.toolAwareChatMessages(
                        structuredHistory: structuredHistory,
                        toolAwareHistory: toolAwareHistory,
                        systemPrompt: effectiveSystemPrompt,
                        dialect: dialect
                    )
                } else {
                    try Self.plainChatMessages(
                        history: structuredHistory,
                        systemPrompt: effectiveSystemPrompt
                    )
                }
            } else {
                nil
            }

        // All non-vision messages are encoded as plain [String: String]
        // dictionaries before the container applies the tokenizer's chat
        // template. For Qwen 2.5 tool history, tool calls are text-encoded into
        // content fields using the same <tool_call>…</tool_call> format the
        // model emits.
        let messages: [[String: String]] = {
            var msgs: [[String: String]] = []
            if let sp = effectiveSystemPrompt, !sp.isEmpty {
                msgs.append(["role": "system", "content": sp])
            }
            if let toolHistory = toolAwareHistory, !toolHistory.isEmpty {
                // Encode tool-aware history entries into the Qwen text format.
                for entry in toolHistory {
                    msgs.append(Self.encodeToolAwareEntryAsText(entry, dialect: dialect))
                }
            } else if !conversationHistory.isEmpty {
                for msg in conversationHistory {
                    msgs.append(["role": msg.role, "content": msg.content])
                }
            } else {
                msgs.append(["role": "user", "content": prompt])
            }
            return msgs
        }()

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        let generationStream = GenerationStream(stream)

        let task = Task { @MainActor [weak self, generationStream] in
            defer {
                Self.logger.debug("MLX generate finished")
            }

            do {
                let outputLimit = config.maxOutputTokens
                var outputTokenCount = 0
                var isFirstToken = true

                // Markers are resolved from two sources, manual-override first:
                //   1. `config.thinkingMarkers` — caller's per-request override.
                //   2. `autoDetectedMarkers` — sniffed from `tokenizer_config.json`'s
                //      Jinja chat template at load time.
                // If both are nil, the model does not advertise reasoning blocks and
                // the parser stays off — raw `<think>` substrings (if the model emits
                // them anyway) surface as visible `.token` text instead of being split
                // into `.thinkingToken` events.
                //
                // `config.maxThinkingTokens == 0` disables thinking entirely (issue #597),
                // overriding both sources above.
                let thinkingDisabled = config.maxThinkingTokens == 0
                let resolvedMarkers = config.thinkingMarkers ?? autoDetectedMarkers
                let useThinkingParser = !thinkingDisabled && resolvedMarkers != nil
                // ThinkingParser must always be initialized (its initializer can't take nil).
                // When useThinkingParser is false the parser is never invoked, so the
                // placeholder marker pair is never observed.
                var thinkingParser = ThinkingParser(markers: resolvedMarkers ?? .qwen3)

                // Instantiate the tool-call parser when tools are configured and the
                // loaded model speaks a known tool-call dialect. The parser is a no-op
                // pass-through when tools are empty or the dialect is unknown.
                let useToolParser = !config.tools.isEmpty && dialect != .unknown
                var toolParser = MLXToolCallParser()

                // Enforces `config.maxThinkingTokens` with the same semantics as
                // LlamaGenerationDriver: a thinking model that runs away on a 16 GB
                // Mac can OOM mid-generation, so when the configured budget is hit
                // we stop emitting further thinking tokens and break out of the
                // MLX stream. Visible `.token` events are never counted toward
                // this budget. See issue #550.
                var thinkingTokenCount = 0
                var thinkingLimitReached = false

                let preparedInput =
                    if let chatMessages {
                        try await modelContainer.prepare(chat: SendableChatMessages(chatMessages))
                    } else {
                        try await modelContainer.prepare(messages: messages)
                    }
                let cache = try await modelContainer.makeCache(parameters: generateConfig)
                var generationInput = preparedInput
                let promptTokenIds: [Int]? = if kvCacheReuseEligible {
                    preparedInput.promptTokenIds
                } else {
                    nil
                }
                if kvCacheReuseEligible, let pendingSnapshotTask {
                    await pendingSnapshotTask.value
                }
                let resolvedSnapshot: PromptCacheSnapshot? =
                    if kvCacheReuseEligible, let self {
                        self.withStateLock { self._promptCacheSnapshot }
                    } else {
                        nil
                    }

                if kvCacheReuseEligible,
                   let snapshot = resolvedSnapshot,
                   let promptTokenIds,
                   Self.isSupportedPromptCache(cache.value),
                   promptTokenIds.count > 1 {
                    let commonPrefixLen = Self.longestCommonPrefixLength(
                        promptTokenIds,
                        snapshot.promptTokens
                    )
                    let reuseLen = min(commonPrefixLen, promptTokenIds.count - 1)
                    if reuseLen > 0,
                       Self.restorePromptCache(
                        snapshot,
                        into: cache,
                        reusedPromptTokenCount: reuseLen
                       ) {
                        generationInput = preparedInput.suffix(from: reuseLen)
                        continuation.yield(.kvCacheReuse(promptTokensReused: reuseLen))
                    }
                }

                let mlxStream = try await modelContainer.generate(
                    input: generationInput,
                    cache: cache,
                    parameters: generateConfig
                )
                // Inserts a brief cooperative yield every N tokens so sustained MLX
                // generation doesn't starve WindowServer's GPU command queue and
                // cause UI hitches in other apps. Mirrors the pattern in SwiftLM's
                // `Server.swift` (50µs sleep every 8 tokens). Configurable via
                // `GenerationConfig.yieldEveryNTokens`; `0` disables the yield.
                let yieldEvery = config.yieldEveryNTokens
                var completionTokenCount = 0
                outer: for await generation in mlxStream {
                    if Task.isCancelled { break }
                    if let text = generation.chunk {
                        // Stage 1: tool-call parsing (suppresses tokens inside <tool_call>…</tool_call>).
                        // Stage 2: thinking parsing on remaining .token events.
                        let stageOneEvents: [GenerationEvent] = useToolParser
                            ? toolParser.process(text)
                            : [.token(text)]

                        for event in stageOneEvents {
                            // Apply thinking parser only to visible token events.
                            let finalEvents: [GenerationEvent]
                            if case .token(let tokenText) = event, useThinkingParser {
                                finalEvents = thinkingParser.process(tokenText)
                            } else {
                                finalEvents = [event]
                            }

                            for finalEvent in finalEvents {
                                if isFirstToken {
                                    switch finalEvent {
                                    case .token, .thinkingToken, .toolCall:
                                        await MainActor.run { generationStream.setPhase(.streaming) }
                                        isFirstToken = false
                                    default: break
                                    }
                                }
                                // Only count visible output tokens toward maxOutputTokens limit.
                                // Tool call events do not count as output tokens.
                                if case .token = finalEvent { outputTokenCount += 1 }
                                continuation.yield(finalEvent)
                                if case .thinkingToken = finalEvent {
                                    thinkingTokenCount += 1
                                    if let limit = config.maxThinkingTokens, thinkingTokenCount >= limit {
                                        thinkingLimitReached = true
                                        break
                                    }
                                }
                            }
                        }
                        if thinkingLimitReached { break outer }
                        if let limit = outputLimit, outputTokenCount >= limit { break }

                        // Per-chunk yield: count every MLX-emitted chunk (regardless
                        // of whether it became a visible token, thinking token, or
                        // got swallowed by the tool-call parser) so the cadence
                        // tracks real generation work.
                        completionTokenCount += 1
                        if yieldEvery > 0 && completionTokenCount % yieldEvery == 0 {
                            if let hook = MLXBackend._yieldHookForTesting {
                                await hook()
                            } else {
                                try? await Task.sleep(for: .microseconds(50))
                            }
                        }
                    }
                }
                // Flush any bytes held back at tag-boundary buffers.
                if useToolParser {
                    for event in toolParser.finalize() {
                        if case .token(let tokenText) = event, useThinkingParser {
                            for finalEvent in thinkingParser.process(tokenText) {
                                continuation.yield(finalEvent)
                            }
                        } else {
                            continuation.yield(event)
                        }
                    }
                }
                for event in thinkingParser.finalize() {
                    continuation.yield(event)
                }
                let snapshotInputs: (MLXPromptCache, [Int])? =
                    if kvCacheReuseEligible, !Task.isCancelled, let promptTokenIds {
                        (cache, promptTokenIds)
                    } else {
                        nil
                    }

                if let self {
                    self.withStateLock { self._isGenerating = false }
                }
                await MainActor.run { generationStream.setPhase(.done) }
                if let self, let (cache, promptTokenIds) = snapshotInputs {
                    self.withStateLock {
                        self._promptCacheWriteToken &+= 1
                        let snapshotWriteToken = self._promptCacheWriteToken
                        // The snapshot must capture on `@MainActor`: every MLX
                        // call inside `capturePromptCacheSnapshot` (copy/eval/
                        // slicing/trim) shares the single-threaded GPU scheduler
                        // with `ModelContainer.generate`. Running it on a free
                        // executor would race the next generation's compute.
                        let snapshotTask = Task<Void, Never> { @MainActor [weak self] in
                            let snapshot = Self.capturePromptCacheSnapshot(
                                from: cache,
                                promptTokens: promptTokenIds
                            )
                            guard let self else { return }
                            self.withStateLock {
                                guard self._promptCacheWriteToken == snapshotWriteToken else { return }
                                self._promptCacheSnapshot = snapshot
                                self._pendingPromptCacheSnapshotTask = nil
                            }
                        }
                        self._pendingPromptCacheSnapshotTask = snapshotTask
                    }
                }
                continuation.finish()
            } catch {
                if let self {
                    self.withStateLock { self._isGenerating = false }
                }
                if !Task.isCancelled {
                    Self.logger.error("MLX generation error: \(error)")
                    await MainActor.run { generationStream.setPhase(.failed(error.localizedDescription)) }
                    continuation.finish(throwing: error)
                    return
                }
                await MainActor.run { generationStream.setPhase(.done) }
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

    // MARK: - Testing

    /// Injects a mock container so unit tests can exercise the generation path
    /// without loading real model weights. Call this before `generate()`.
    ///
    /// Not part of the public API — visible to `BaseChatBackendsTests` via `@testable import`.
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
            invalidatePromptCacheLocked()
            _kvCacheReuseEligible = enableKVCacheReuse
            _hasInitializedRuntime = false
        }
    }

    func _hasPromptCacheSnapshotForTesting() -> Bool {
        withStateLock { _promptCacheSnapshot != nil || _pendingPromptCacheSnapshotTask != nil }
    }

    func _isPromptCacheSnapshotReadyForTesting() -> Bool {
        withStateLock { _promptCacheSnapshot != nil && _pendingPromptCacheSnapshotTask == nil }
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
        // compile the metallib, so clearing the cache after `_inject(...)`
        // would trip the same failure this guard exists to avoid.
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
            invalidatePromptCacheLocked()
            _kvCacheReuseEligible = false
            _hasInitializedRuntime = false
            return had
        }
        if hadInitializedRuntime {
            Memory.clearCache()
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
            invalidatePromptCacheLocked()
        }
    }

    /// Evicts pooled Metal GPU buffers that may contain KV-cache residue from
    /// prior inference turns.
    ///
    /// MLX does not expose an API to explicitly zero Metal `MTLBuffer` contents
    /// after the fact; the best available measure is to evict all pooled buffers
    /// via `Memory.clearCache()` so they are returned to the OS rather than
    /// reused by the next request. This is the same call made by
    /// ``unloadModel()``. The prompt-cache state is also invalidated so the next
    /// ``generate(_:config:)`` call starts fresh.
    ///
    /// **Note**: this provides an eviction guarantee, NOT a zero guarantee. Any
    /// residue in currently-active Metal allocations (e.g. mid-stream) is
    /// not affected.
    public func secureWipe() {
        let hasRuntime = withStateLock { () -> Bool in
            invalidatePromptCacheLocked()
            return _hasInitializedRuntime
        }
        #if MLX
        if hasRuntime {
            Memory.clearCache()
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

// MARK: - Tool-Aware Entry Encoding

extension MLXBackend {
    /// Encodes a ``ToolAwareHistoryEntry`` into a plain `[String: String]` message
    /// compatible with MLX chat-template preparation.
    ///
    /// For the Qwen 2.5 dialect:
    /// - Assistant entries with `toolCalls` have the calls serialised as
    ///   `<tool_call>{"name":…,"arguments":…}</tool_call>` appended to (or
    ///   replacing) the textual content.
    /// - Tool-role entries (carrying a ``ToolResult``) are represented as
    ///   `role: "tool"` with the result content. The MLX chat template for
    ///   Qwen maps the `tool` role to an `<tool_response>` block internally.
    ///
    /// For the `.unknown` dialect (and plain text turns) the entry collapses to
    /// a simple `{role, content}` pair.
    static func encodeToolAwareEntryAsText(
        _ entry: ToolAwareHistoryEntry,
        dialect: MLXToolDialect
    ) -> [String: String] {
        // For non-Qwen dialects or plain turns, fall back to the bare shape.
        guard dialect == .qwen25 else {
            return ["role": entry.role, "content": entry.content]
        }

        if let calls = entry.toolCalls, !calls.isEmpty {
            // Assistant turn that triggered tool calls: encode calls as text.
            var parts: [String] = []
            if !entry.content.isEmpty {
                parts.append(entry.content)
            }
            for call in calls {
                let argsValue: Any
                if let data = call.arguments.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    argsValue = parsed
                } else {
                    argsValue = [String: Any]()
                }
                let callObj: [String: Any] = ["name": call.toolName, "arguments": argsValue]
                if let data = try? JSONSerialization.data(withJSONObject: callObj),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    parts.append("<tool_call>\n\(jsonStr)\n</tool_call>")
                }
            }
            return ["role": "assistant", "content": parts.joined(separator: "\n")]
        }

        // Tool result turn: pass role and content as-is.
        // The Qwen tokenizer template handles `role: "tool"` natively.
        return ["role": entry.role, "content": entry.content]
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
}
#endif
