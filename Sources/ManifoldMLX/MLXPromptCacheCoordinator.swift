#if MLX
import Foundation
@preconcurrency import MLX
import MLXLMCommon
import os
import ManifoldInference

/// Coordinates prompt KV-cache reuse for `MLXBackend`.
///
/// ## Type-aware, per-layer reuse (hybrid architectures)
///
/// Reuse is decided **per layer**, keyed off each layer's own cache type, not
/// gated on the whole model being a single homogeneous `KVCacheSimple` stack.
/// Hybrid architectures (e.g. Qwen3-Next-style models that mix full-attention
/// layers with recurrent / sliding-window layers) therefore no longer fall off
/// an invisible cliff: layers whose cache type can be reduced to the reuse
/// length are reused, and when a layer genuinely cannot be reused the turn
/// falls back to a full prefill with a logged ``PromptCacheReuseReason`` rather
/// than silently re-prefilling.
///
/// **Correctness boundary (unchanged from the v0.5.3 incident contract):** the
/// number of reused tokens is always the byte-exact common-prefix length of the
/// two prompts. Per-layer handling only changes *which layers* can be restored
/// to that length — never *whether* the prefix must match exactly. A layer is
/// reducible to the reuse length `L` only when its post-restore offset already
/// equals `L` (verbatim continuation, valid for any cache type) or the cache is
/// trimmable and `trim` removes exactly the excess (the MLX library's own
/// `trimPromptCache` contract). Any per-layer failure aborts reuse for the turn
/// and a fresh cache is allocated for the full prompt — there is no unsafe
/// partial reuse.
// @_spi(Testing): published only for backend test targets (companion-package split, #1749).
@_spi(Testing) public enum MLXPromptCacheCoordinator {
    private static let logger = Logger(
        subsystem: ManifoldConfiguration.shared.logSubsystem,
        category: "inference"
    )

    public struct CachedLayerState {
        let cacheTypeName: String
        let offset: Int
        let state: [MLXArray]
        let metaState: [String]

        public init(cacheTypeName: String, offset: Int, state: [MLXArray], metaState: [String]) {
            self.cacheTypeName = cacheTypeName
            self.offset = offset
            self.state = state
            self.metaState = metaState
        }
    }

    public struct Snapshot {
        let promptTokens: [Int]
        let layers: [CachedLayerState]

        public init(promptTokens: [Int], layers: [CachedLayerState]) {
            self.promptTokens = promptTokens
            self.layers = layers
        }
    }

    public struct State {
        public var snapshot: Snapshot?
        public var pendingSnapshotTask: Task<Void, Never>?
        public var writeToken: UInt64 = 0

        public init() {}

        public mutating func invalidate() {
            pendingSnapshotTask?.cancel()
            pendingSnapshotTask = nil
            snapshot = nil
            writeToken &+= 1
        }

        public var hasSnapshotOrPending: Bool {
            snapshot != nil || pendingSnapshotTask != nil
        }

        public var isSnapshotReady: Bool {
            snapshot != nil && pendingSnapshotTask == nil
        }
    }

    struct SnapshotCaptureInputs {
        let cache: MLXPromptCache
        let promptTokenIds: [Int]
    }

    // MARK: - Diagnostic reasons

    /// Why prompt-cache reuse did or did not happen on a given turn.
    ///
    /// Surfaced (logged) on a miss so a hybrid model that can't reuse fails
    /// *loudly* with a reason rather than silently re-prefilling.
    public enum PromptCacheReuseReason: Equatable, Sendable, CustomStringConvertible {
        /// Reuse succeeded: `promptTokensReused` leading tokens were restored.
        case reused(promptTokensReused: Int)
        /// Reuse was not attempted (feature disabled / no eligible snapshot path).
        case notEligible
        /// No usable snapshot exists from a prior turn.
        case noSnapshot
        /// The prepared prompt was too short to reuse (need more than one token).
        case promptTooShort
        /// The new prompt shares no usable token prefix with the snapshot.
        case noCommonPrefix
        /// Snapshot and live layer counts disagree (model/cache shape changed).
        case layerCountMismatch(snapshot: Int, live: Int)
        /// A layer's live cache type differs from the snapshot's recorded type.
        case layerTypeMismatch(layerIndex: Int, expected: String, found: String)
        /// A layer cannot be reduced to the reuse length: its cache type is not
        /// trimmable and the reuse length is shorter than the cached prefix
        /// (e.g. a recurrent/hybrid layer after a divergent edit).
        case layerNotReusable(layerIndex: Int, cacheTypeName: String)

        public var didReuse: Bool {
            if case .reused = self { return true }
            return false
        }

        public var description: String {
            switch self {
            case .reused(let n): return "reused(\(n) prompt tokens)"
            case .notEligible: return "not eligible for reuse this turn"
            case .noSnapshot: return "no snapshot from a prior turn"
            case .promptTooShort: return "prompt too short to reuse"
            case .noCommonPrefix: return "no common prompt prefix"
            case .layerCountMismatch(let s, let l):
                return "layer count mismatch (snapshot=\(s), live=\(l))"
            case .layerTypeMismatch(let i, let e, let f):
                return "layer \(i) type mismatch (expected \(e), found \(f))"
            case .layerNotReusable(let i, let t):
                return "layer \(i) (\(t)) is not reusable at the byte-exact prefix length"
            }
        }
    }

    /// Why a post-generation snapshot was or wasn't captured for next-turn reuse.
    enum PromptCacheCaptureReason: Equatable, Sendable, CustomStringConvertible {
        case captured(layers: Int)
        case emptyPrompt
        case noCaches
        case cancelled
        /// A layer's offset is below the prompt length — its prompt-prefix state
        /// can no longer be recovered.
        case layerOffsetBelowPrompt(layerIndex: Int)
        /// A layer holds more tokens than the prompt (generated tail) but its
        /// cache type cannot be trimmed back to prompt-only state (e.g. a
        /// recurrent/hybrid layer captured post-generation).
        case layerNotTrimmable(layerIndex: Int, cacheTypeName: String)

        var description: String {
            switch self {
            case .captured(let n): return "captured(\(n) layers)"
            case .emptyPrompt: return "empty prompt"
            case .noCaches: return "no cache layers"
            case .cancelled: return "generation cancelled"
            case .layerOffsetBelowPrompt(let i):
                return "layer \(i) offset is below the prompt length"
            case .layerNotTrimmable(let i, let t):
                return "layer \(i) (\(t)) cannot be trimmed back to prompt-only state"
            }
        }
    }

    /// Per-layer descriptor consumed by ``planReuse(layers:liveLayerCount:reusedCount:)``.
    ///
    /// Carries only the non-GPU properties the reuse decision needs, so the
    /// planning rule is unit-testable without touching Metal.
    public struct LayerReusePlanInput: Equatable {
        let snapshotTypeName: String
        let snapshotOffset: Int
        let snapshotStateIsEmpty: Bool
        let liveTypeName: String
        let liveIsTrimmable: Bool
        let liveIsKVCacheSimple: Bool

        public init(
            snapshotTypeName: String,
            snapshotOffset: Int,
            snapshotStateIsEmpty: Bool,
            liveTypeName: String,
            liveIsTrimmable: Bool,
            liveIsKVCacheSimple: Bool
        ) {
            self.snapshotTypeName = snapshotTypeName
            self.snapshotOffset = snapshotOffset
            self.snapshotStateIsEmpty = snapshotStateIsEmpty
            self.liveTypeName = liveTypeName
            self.liveIsTrimmable = liveIsTrimmable
            self.liveIsKVCacheSimple = liveIsKVCacheSimple
        }
    }

    /// Result of `prepareInputAndCache(...)`.
    struct PreparedGenerationInputs {
        let generationInput: MLXPreparedInput
        let cache: MLXPromptCache
        /// Captured prompt token IDs when KV-cache reuse is eligible — used to
        /// snapshot the cache after generation finishes. `nil` otherwise.
        let promptTokenIds: [Int]?
        /// Number of leading prompt tokens whose KV state was restored from
        /// the previous turn. `0` when no reuse occurred.
        let reuseLen: Int
        /// Diagnostic outcome of the reuse attempt for this turn.
        let reuseReason: PromptCacheReuseReason
    }

    public static func longestCommonPrefixLength(_ lhs: [Int], _ rhs: [Int]) -> Int {
        zip(lhs, rhs).prefix(while: { $0 == $1 }).count
    }

    // MARK: - Pure, Metal-free reuse planning

    /// The single source of truth for whether a layer currently holding
    /// `currentOffset` tokens can be reduced to exactly `targetOffset`.
    ///
    /// Verbatim continuation (`currentOffset == targetOffset`) is valid for any
    /// cache type; otherwise the surplus can only be dropped from a trimmable
    /// cache. Shared by both the capture and restore paths and by `planReuse`.
    public static func layerCanReduce(
        currentOffset: Int,
        targetOffset: Int,
        isTrimmable: Bool
    ) -> Bool {
        guard currentOffset >= targetOffset else { return false }
        return currentOffset == targetOffset || isTrimmable
    }

    /// Decides whether the full layer set can be restored to `reusedCount`,
    /// returning `.reused` when every layer is eligible or the first blocking
    /// reason otherwise. Pure — performs no GPU work — so it is the unit-test
    /// seam for type-aware, per-layer eligibility.
    public static func planReuse(
        layers: [LayerReusePlanInput],
        liveLayerCount: Int,
        reusedCount: Int
    ) -> PromptCacheReuseReason {
        guard reusedCount > 0 else { return .noCommonPrefix }
        guard liveLayerCount == layers.count else {
            return .layerCountMismatch(snapshot: layers.count, live: liveLayerCount)
        }
        for (index, layer) in layers.enumerated() {
            guard layer.liveTypeName == layer.snapshotTypeName else {
                return .layerTypeMismatch(
                    layerIndex: index,
                    expected: layer.snapshotTypeName,
                    found: layer.liveTypeName
                )
            }
            // Empty-state layers are restored by setting the offset directly,
            // which only `KVCacheSimple` supports here.
            if layer.snapshotStateIsEmpty, !layer.liveIsKVCacheSimple {
                return .layerNotReusable(
                    layerIndex: index,
                    cacheTypeName: layer.snapshotTypeName
                )
            }
            guard layerCanReduce(
                currentOffset: layer.snapshotOffset,
                targetOffset: reusedCount,
                isTrimmable: layer.liveIsTrimmable
            ) else {
                return .layerNotReusable(
                    layerIndex: index,
                    cacheTypeName: layer.snapshotTypeName
                )
            }
        }
        return .reused(promptTokensReused: reusedCount)
    }

    /// Builds `LayerReusePlanInput`s by reading only the non-GPU properties of
    /// the freshly-allocated live caches and the recorded snapshot. Lets callers
    /// (and tests with fake `KVCache`s) drive `planReuse` without materialising
    /// tensors.
    public static func planInputs(
        live: [any KVCache],
        snapshot: Snapshot
    ) -> [LayerReusePlanInput] {
        zip(live, snapshot.layers).map { liveCache, layer in
            LayerReusePlanInput(
                snapshotTypeName: layer.cacheTypeName,
                snapshotOffset: layer.offset,
                snapshotStateIsEmpty: layer.state.isEmpty,
                liveTypeName: String(describing: type(of: liveCache)),
                liveIsTrimmable: liveCache.isTrimmable,
                liveIsKVCacheSimple: liveCache is KVCacheSimple
            )
        }
    }

    /// Prepares the model input, allocates a KV cache, and applies the
    /// longest-common-prefix reuse heuristic when an eligible snapshot exists.
    ///
    /// **CRITICAL:** the reuse path here preserves the byte-exact prefix-match
    /// contract — `longestCommonPrefixLength` clamped to
    /// `promptTokenIds.count - 1`, gated by `promptTokenIds.count > 1`. Reuse is
    /// now decided per layer (see ``restorePromptCache``); when any layer is not
    /// reusable the cache is re-allocated fresh for the full prompt so a partial
    /// restore can never leak into a full-prefill turn. Behaviour drift here
    /// corrupts the KV cache across turns (see v0.5.3 incident).
    @MainActor
    static func prepareInputAndCache(
        container: any MLXModelContainerProtocol,
        chatMessages: [Chat.Message]?,
        messages: [[String: String]],
        generateConfig: GenerateParameters,
        kvCacheReuseEligible: Bool,
        snapshot: Snapshot?
    ) async throws -> PreparedGenerationInputs {
        let preparedInput =
            if let chatMessages {
                try await container.prepare(chat: SendableChatMessages(chatMessages))
            } else {
                try await container.prepare(messages: messages)
            }
        var cache = try await container.makeCache(parameters: generateConfig)
        let promptTokenIds: [Int]? = if kvCacheReuseEligible {
            preparedInput.promptTokenIds
        } else {
            nil
        }

        var generationInput = preparedInput
        var reuseLen = 0
        var reuseReason: PromptCacheReuseReason = kvCacheReuseEligible ? .noSnapshot : .notEligible

        if kvCacheReuseEligible, !cache.value.isEmpty {
            guard let snapshot, let promptTokenIds else {
                // reuseReason already .noSnapshot
                return PreparedGenerationInputs(
                    generationInput: generationInput,
                    cache: cache,
                    promptTokenIds: promptTokenIds,
                    reuseLen: reuseLen,
                    reuseReason: reuseReason
                )
            }
            guard promptTokenIds.count > 1 else {
                reuseReason = .promptTooShort
                return PreparedGenerationInputs(
                    generationInput: generationInput,
                    cache: cache,
                    promptTokenIds: promptTokenIds,
                    reuseLen: reuseLen,
                    reuseReason: reuseReason
                )
            }
            let commonPrefixLen = longestCommonPrefixLength(
                promptTokenIds,
                snapshot.promptTokens
            )
            let candidate = min(commonPrefixLen, promptTokenIds.count - 1)
            reuseReason = restorePromptCache(
                snapshot,
                into: cache,
                reusedPromptTokenCount: candidate
            )
            if case .reused(let restored) = reuseReason {
                generationInput = preparedInput.suffix(from: restored)
                reuseLen = restored
            } else {
                // A per-layer failure may have partially mutated `cache`.
                // Discard it and allocate a clean cache for the full prompt so
                // no half-restored state ever pairs with a full prefill.
                cache = try await container.makeCache(parameters: generateConfig)
                logger.debug(
                    "MLX prompt-cache reuse declined: \(reuseReason.description, privacy: .public)"
                )
            }
        }

        return PreparedGenerationInputs(
            generationInput: generationInput,
            cache: cache,
            promptTokenIds: promptTokenIds,
            reuseLen: reuseLen,
            reuseReason: reuseReason
        )
    }

    static func makeSnapshotCaptureTask(
        cache: MLXPromptCache,
        promptTokenIds: [Int],
        writeToken: UInt64,
        store: @escaping @MainActor @Sendable (UInt64, Snapshot?) -> Void
    ) -> Task<Void, Never> {
        Task<Void, Never> { @MainActor in
            let snapshot = capturePromptCacheSnapshot(
                from: cache,
                promptTokens: promptTokenIds
            )
            store(writeToken, snapshot)
        }
    }

    /// Captures prompt-only KV state for the next turn.
    ///
    /// Contract assumptions taken from the currently pinned `mlx-swift-lm`:
    /// 1. `LanguageModel.prepare(_:cache:windowSize:)` consumes any cached prefix
    ///    from the front of the prepared prompt and only evaluates the remaining
    ///    suffix, so restored caches must be paired with the uncached prompt tail.
    /// 2. `KVCache.copy()/state/metaState/trim(_:)` are sufficient to clone and
    ///    shrink prompt-only state for trimmable caches — the same contract MLX's
    ///    own `trimPromptCache` relies on.
    /// 3. Future `mlx-swift-lm` bumps must rerun the MLX KV-cache integration and
    ///    performance suite before this contract is trusted unchanged.
    ///
    /// Marked `@MainActor` because every MLX call here (`copy()`, `eval`,
    /// `state` slicing, `trim`) shares the same single-threaded GPU scheduler
    /// as `ModelContainer.generate()`; running off-main risks racy crashes /
    /// cache corruption.
    @MainActor
    static func capturePromptCacheSnapshot(
        from cache: MLXPromptCache,
        promptTokens: [Int]
    ) -> Snapshot? {
        let (snapshot, reason) = captureSnapshot(from: cache, promptTokens: promptTokens)
        if snapshot == nil {
            logger.debug(
                "MLX prompt-cache snapshot skipped: \(reason.description, privacy: .public)"
            )
        }
        return snapshot
    }

    /// Per-layer snapshot capture. Returns the captured snapshot (or `nil`) plus
    /// the diagnostic reason. Each layer is independently reduced to prompt-only
    /// state via its own cache type's `trim`; a layer that cannot be reduced
    /// (e.g. a recurrent/hybrid layer post-generation) is reported rather than
    /// silently discarding the whole snapshot.
    @MainActor
    static func captureSnapshot(
        from cache: MLXPromptCache,
        promptTokens: [Int]
    ) -> (Snapshot?, PromptCacheCaptureReason) {
        guard !promptTokens.isEmpty else { return (nil, .emptyPrompt) }
        guard !cache.value.isEmpty else { return (nil, .noCaches) }
        // Early-exit if the surrounding generation task was cancelled — `copy()`
        // and `eval` materialise full prompt-prefix tensors per layer, which is
        // expensive enough to be worth skipping when a reset/unload already
        // invalidated the snapshot we'd be writing.
        if Task.isCancelled { return (nil, .cancelled) }

        var layers: [CachedLayerState] = []
        layers.reserveCapacity(cache.value.count)
        for (index, original) in cache.value.enumerated() {
            if Task.isCancelled { return (nil, .cancelled) }
            guard original.offset >= promptTokens.count else {
                return (nil, .layerOffsetBelowPrompt(layerIndex: index))
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
                    return (
                        nil,
                        .layerNotTrimmable(
                            layerIndex: index,
                            cacheTypeName: String(describing: type(of: copy))
                        )
                    )
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
        return (
            Snapshot(promptTokens: promptTokens, layers: layers),
            .captured(layers: layers.count)
        )
    }

    /// Restores `snapshot` into `cache`, reducing each layer to exactly
    /// `reusedPromptTokenCount` tokens. Returns the per-layer-aware reuse
    /// outcome; on any non-`.reused` result the caller must treat `cache` as
    /// spent (it may be partially mutated) and allocate a fresh one.
    @MainActor
    static func restorePromptCache(
        _ snapshot: Snapshot,
        into cache: MLXPromptCache,
        reusedPromptTokenCount: Int
    ) -> PromptCacheReuseReason {
        guard reusedPromptTokenCount > 0 else { return .noCommonPrefix }
        guard cache.value.count == snapshot.layers.count else {
            return .layerCountMismatch(
                snapshot: snapshot.layers.count,
                live: cache.value.count
            )
        }

        for (index, layer) in snapshot.layers.enumerated() {
            var target = cache.value[index]
            let liveTypeName = String(describing: type(of: target))
            guard liveTypeName == layer.cacheTypeName else {
                return .layerTypeMismatch(
                    layerIndex: index,
                    expected: layer.cacheTypeName,
                    found: liveTypeName
                )
            }
            if layer.state.isEmpty {
                guard let simple = target as? KVCacheSimple else {
                    return .layerNotReusable(
                        layerIndex: index,
                        cacheTypeName: layer.cacheTypeName
                    )
                }
                simple.offset = layer.offset
                simple.metaState = layer.metaState
            } else {
                target.state = layer.state.map { $0[.ellipsis] }
                target.metaState = layer.metaState
            }

            // `layerCanReduce` is the pre-flight model; the offset/trim guards
            // below are the authoritative arbiter against the *post-restore*
            // cache (e.g. a rotating cache whose trimmability depends on its
            // restored offset).
            guard target.offset >= reusedPromptTokenCount else {
                return .layerNotReusable(
                    layerIndex: index,
                    cacheTypeName: layer.cacheTypeName
                )
            }
            let excess = target.offset - reusedPromptTokenCount
            if excess > 0 {
                guard target.isTrimmable, target.trim(excess) == excess else {
                    return .layerNotReusable(
                        layerIndex: index,
                        cacheTypeName: layer.cacheTypeName
                    )
                }
            }
        }

        eval(cache.value)
        return .reused(promptTokensReused: reusedPromptTokenCount)
    }
}
#endif
