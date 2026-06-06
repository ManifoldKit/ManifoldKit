#if MLX
import Foundation
import MLXLMCommon

// MARK: - SendableLMInput

/// Wraps the non-Sendable `LMInput` so it can be passed across concurrency boundaries.
///
/// This is `@unchecked Sendable` because `LMInput` holds `MLXArray` values that are not
/// marked `Sendable`. The wrapper is safe when access to the underlying value is
/// serialised — e.g. produced and consumed within the same `Task`.
struct SendableLMInput: @unchecked Sendable {
    let value: LMInput

    init(_ value: LMInput) {
        self.value = value
    }
}

struct SendableKVCacheList: @unchecked Sendable {
    let value: [any KVCache]

    init(_ value: [any KVCache]) {
        self.value = value
    }
}

// MARK: - MockMLXModelContainer

/// Fake model container for unit-testing `MLXBackend` generation without hardware.
///
/// Conforms to `MLXModelContainerProtocol` via an extension below (where the
/// internal protocol is visible). This avoids importing `ManifoldBackends` from
/// `ManifoldTestSupport`.
final class MockMLXModelContainer: @unchecked Sendable {

    // MARK: - Configuration

    /// Tokens the mock yields from `generate`. Defaults to a two-token sequence.
    var tokensToYield: [String] = ["Hello", " world"]

    /// When set, `generate` throws this error instead of yielding tokens.
    var generateError: Error?

    /// Simulates a chat-template / tokenizer rejection at `apply_chat_template` time.
    ///
    /// When set, `generate(messages:parameters:)` throws this error before yielding
    /// any token — modeling the failure mode where the loaded tokenizer either has
    /// no chat template (`tokenizer_config.json` missing the `chat_template` field)
    /// or the template rejects the supplied message set (e.g. missing
    /// `<|assistant|>` marker, wrong role ordering). The error surfaces unwrapped
    /// through `MLXBackend.generate`'s GenerationStream — see issue #551.
    var simulatedTokenizerApplyFailure: Error?

    /// Optional stand-in for the tokenizer's `chat_template` field. The mock does
    /// NOT itself apply a Jinja template — production MLXModelContainer does that
    /// internally — but tests can set this to document which template shape they
    /// are exercising and assert the backend hands compatible messages along.
    var simulatedChatTemplate: String?

    /// Prepared prompt-token batches returned by successive `prepare` calls.
    ///
    /// When empty, the mock synthesizes a small token sequence from the message count.
    var preparedTokenBatches: [[Int]] = []

    /// Factory used to create the explicit cache passed to generation.
    var cacheFactory: @Sendable () -> [any KVCache] = { [KVCacheSimple()] }

    /// Extra tail tokens the mock appends to the cache during generation to model
    /// completion tokens extending beyond the prompt.
    var simulatedCacheCompletionTokenCount = 0

    // MARK: - Observation

    /// Number of times prepared generation was called.
    private(set) var generateCallCount = 0

    /// Number of times `prepare(messages:)` was called.
    private(set) var prepareCallCount = 0

    /// Number of times `makeCache(parameters:)` was called.
    private(set) var makeCacheCallCount = 0

    /// Last messages passed to `prepare`.
    private(set) var lastMessages: [[String: String]]?

    /// Last structured chat messages passed to `prepare(chat:)`.
    private(set) var lastChatMessages: [Chat.Message]?

    /// Last `GenerateParameters` value passed to generation. Useful for asserting
    /// that `MLXBackend` forwards `temperature` / `topP` / `topK` / `minP` /
    /// `repetitionPenalty` from the caller's `GenerationConfig`.
    private(set) var lastParameters: GenerateParameters?

    /// Last prepared prompt-token batch returned by `prepare`.
    private(set) var lastPreparedTokenIds: [Int]?

    /// Cache offsets observed at the start of generation.
    private(set) var lastInitialCacheOffsets: [Int]?

    init() {}

    // MARK: - Helpers consumed by MLXModelContainerProtocol conformance

    func prepareForGeneration(
        messages: [[String: String]]
    ) async throws -> [Int] {
        prepareCallCount += 1
        lastMessages = messages
        lastChatMessages = nil

        let promptTokens: [Int]
        if !preparedTokenBatches.isEmpty {
            promptTokens = preparedTokenBatches.removeFirst()
        } else {
            promptTokens = Array(1 ... max(messages.count, 1))
        }
        lastPreparedTokenIds = promptTokens
        return promptTokens
    }

    func prepareForGeneration(
        chat: [Chat.Message]
    ) async throws -> [Int] {
        prepareCallCount += 1
        lastChatMessages = chat
        lastMessages = nil

        let promptTokens: [Int]
        if !preparedTokenBatches.isEmpty {
            promptTokens = preparedTokenBatches.removeFirst()
        } else {
            promptTokens = Array(1 ... max(chat.count, 1))
        }
        lastPreparedTokenIds = promptTokens
        return promptTokens
    }

    func makeCacheForGeneration(parameters: GenerateParameters) -> [any KVCache] {
        makeCacheCallCount += 1
        return cacheFactory()
    }

    func generatePreparedInput(
        promptTokenIds: [Int],
        cache: SendableKVCacheList?,
        parameters: GenerateParameters
    ) async throws -> AsyncStream<Generation> {
        generateCallCount += 1
        lastParameters = parameters
        lastInitialCacheOffsets = cache?.value.map(\.offset)
        if let error = simulatedTokenizerApplyFailure { throw error }
        if let error = generateError { throw error }

        let tokens = tokensToYield
        let cache = cache
        let promptTokenCount = promptTokenIds.count
        let completionTokenCount = simulatedCacheCompletionTokenCount
        return AsyncStream { continuation in
            let producerTask = Task { [tokens, cache, promptTokenCount, completionTokenCount] in
                for token in tokens {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.yield(.chunk(token))
                    await Task.yield()
                }
                if let cache {
                    let totalTokenCount = promptTokenCount + completionTokenCount
                    for layer in cache.value {
                        Self.setCacheOffset(layer, tokenCount: totalTokenCount)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                producerTask.cancel()
            }
        }
    }

    private static func setCacheOffset(_ cache: any KVCache, tokenCount: Int) {
        guard let cache = cache as? KVCacheSimple else { return }
        cache.offset = max(tokenCount, 0)
    }
}
#endif
