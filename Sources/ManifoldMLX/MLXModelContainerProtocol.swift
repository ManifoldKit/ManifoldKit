#if MLX
import MLXLMCommon

struct MLXPreparedInput: @unchecked Sendable {
    private let value: LMInput?
    private let promptTokenIdsOverride: [Int]?

    init(_ value: LMInput) {
        self.value = value
        self.promptTokenIdsOverride = nil
    }

    init(promptTokenIds: [Int]) {
        self.value = nil
        self.promptTokenIdsOverride = promptTokenIds
    }

    var lmInput: LMInput {
        guard let value else {
            preconditionFailure("Test-only MLXPreparedInput has no LMInput payload")
        }
        return value
    }

    var promptTokenIds: [Int] {
        promptTokenIdsOverride ?? lmInput.text.tokens.asArray(Int.self)
    }

    func suffix(from reusedPromptTokenCount: Int) -> MLXPreparedInput {
        guard reusedPromptTokenCount > 0 else { return self }
        if let value {
            let remainingText = value.text[text: reusedPromptTokenCount...]
            return MLXPreparedInput(
                LMInput(text: remainingText, image: value.image, video: value.video)
            )
        }
        return MLXPreparedInput(promptTokenIds: Array(promptTokenIds.dropFirst(reusedPromptTokenCount)))
    }
}

struct MLXPromptCache: @unchecked Sendable {
    let value: [any KVCache]

    init(_ value: [any KVCache]) {
        self.value = value
    }
}

struct SendableChatMessages: @unchecked Sendable {
    let value: [Chat.Message]

    init(_ value: [Chat.Message]) {
        self.value = value
    }
}

/// Abstraction over `ModelContainer` so `MLXBackend` can be tested without real hardware.
///
/// `LMInput` and `[KVCache]` are wrapped so `MLXBackend` can own prompt preparation,
/// cache creation, prefix reuse, and token streaming while the concrete
/// `ModelContainer` conformance keeps the underlying MLX types off the public API.
protocol MLXModelContainerProtocol: Sendable {
    func prepare(messages: [[String: String]]) async throws -> MLXPreparedInput
    func prepare(chat: SendableChatMessages) async throws -> MLXPreparedInput
    func makeCache(parameters: GenerateParameters) async throws -> MLXPromptCache
    func generate(
        input: MLXPreparedInput,
        cache: MLXPromptCache?,
        parameters: GenerateParameters
    ) async throws -> AsyncStream<Generation>
}

extension ModelContainer: MLXModelContainerProtocol {
    func prepare(messages: [[String: String]]) async throws -> MLXPreparedInput {
        let input = try await prepare(input: .init(messages: messages))
        return MLXPreparedInput(input)
    }

    func prepare(chat: SendableChatMessages) async throws -> MLXPreparedInput {
        try await perform(nonSendable: chat.value) { context, chat in
            let input = try await context.processor.prepare(input: .init(chat: chat))
            return MLXPreparedInput(input)
        }
    }

    func makeCache(parameters: GenerateParameters) async throws -> MLXPromptCache {
        await perform { context in
            MLXPromptCache(context.model.newCache(parameters: parameters))
        }
    }

    func generate(
        input: MLXPreparedInput,
        cache: MLXPromptCache?,
        parameters: GenerateParameters
    ) async throws -> AsyncStream<Generation> {
        try await perform(nonSendable: (input.lmInput, cache?.value)) { context, values in
            let (input, cache) = values
            return try MLXLMCommon.generate(
                input: input,
                cache: cache,
                parameters: parameters,
                context: context,
                wiredMemoryTicket: nil
            )
        }
    }
}
#endif
