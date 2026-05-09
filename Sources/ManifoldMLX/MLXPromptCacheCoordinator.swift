#if MLX
import Foundation
@preconcurrency import MLX
import MLXLMCommon
import ManifoldInference

/// Coordinates prompt KV-cache reuse for `MLXBackend`.
enum MLXPromptCacheCoordinator {
    struct CachedLayerState {
        let cacheTypeName: String
        let offset: Int
        let state: [MLXArray]
        let metaState: [String]
    }

    struct Snapshot {
        let promptTokens: [Int]
        let layers: [CachedLayerState]
    }

    struct State {
        var snapshot: Snapshot?
        var pendingSnapshotTask: Task<Void, Never>?
        var writeToken: UInt64 = 0

        mutating func invalidate() {
            pendingSnapshotTask?.cancel()
            pendingSnapshotTask = nil
            snapshot = nil
            writeToken &+= 1
        }

        var hasSnapshotOrPending: Bool {
            snapshot != nil || pendingSnapshotTask != nil
        }

        var isSnapshotReady: Bool {
            snapshot != nil && pendingSnapshotTask == nil
        }
    }

    struct SnapshotCaptureInputs {
        let cache: MLXPromptCache
        let promptTokenIds: [Int]
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
    }

    static func longestCommonPrefixLength(_ lhs: [Int], _ rhs: [Int]) -> Int {
        zip(lhs, rhs).prefix(while: { $0 == $1 }).count
    }

    /// Prepares the model input, allocates a KV cache, and applies the
    /// longest-common-prefix reuse heuristic when an eligible snapshot exists.
    ///
    /// **CRITICAL:** the reuse path here is byte-identical to the inline
    /// version it replaced — `longestCommonPrefixLength` clamped to
    /// `promptTokenIds.count - 1`, gated by `isSupportedPromptCache` and
    /// `promptTokenIds.count > 1`. Behaviour drift here corrupts the KV cache
    /// across turns (see v0.5.3 incident).
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
        let cache = try await container.makeCache(parameters: generateConfig)
        let promptTokenIds: [Int]? = if kvCacheReuseEligible {
            preparedInput.promptTokenIds
        } else {
            nil
        }

        var generationInput = preparedInput
        var reuseLen = 0
        if kvCacheReuseEligible,
           let snapshot,
           let promptTokenIds,
           isSupportedPromptCache(cache.value),
           promptTokenIds.count > 1 {
            let commonPrefixLen = longestCommonPrefixLength(
                promptTokenIds,
                snapshot.promptTokens
            )
            let candidate = min(commonPrefixLen, promptTokenIds.count - 1)
            if candidate > 0,
               restorePromptCache(snapshot, into: cache, reusedPromptTokenCount: candidate) {
                generationInput = preparedInput.suffix(from: candidate)
                reuseLen = candidate
            }
        }

        return PreparedGenerationInputs(
            generationInput: generationInput,
            cache: cache,
            promptTokenIds: promptTokenIds,
            reuseLen: reuseLen
        )
    }

    static func isSupportedPromptCache(_ caches: [any KVCache]) -> Bool {
        !caches.isEmpty && caches.allSatisfy { $0 is KVCacheSimple }
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
    static func capturePromptCacheSnapshot(
        from cache: MLXPromptCache,
        promptTokens: [Int]
    ) -> Snapshot? {
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
        return Snapshot(promptTokens: promptTokens, layers: layers)
    }

    private static func restorePromptCache(
        _ snapshot: Snapshot,
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
}
#endif
