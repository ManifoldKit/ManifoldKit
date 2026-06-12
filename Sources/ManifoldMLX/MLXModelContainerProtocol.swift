#if MLX
import MLXLMCommon

// @_spi(Testing): published only for backend test targets (companion-package
// split, #1749) — keeps the underlying MLX types off the supported public API.
@_spi(Testing) public struct MLXPreparedInput: @unchecked Sendable {
    private let value: LMInput?
    private let promptTokenIdsOverride: [Int]?

    public init(_ value: LMInput) {
        self.value = value
        self.promptTokenIdsOverride = nil
    }

    public init(promptTokenIds: [Int]) {
        self.value = nil
        self.promptTokenIdsOverride = promptTokenIds
    }

    public var lmInput: LMInput {
        guard let value else {
            preconditionFailure("Test-only MLXPreparedInput has no LMInput payload")
        }
        return value
    }

    public var promptTokenIds: [Int] {
        promptTokenIdsOverride ?? lmInput.text.tokens.asArray(Int.self)
    }

    public func suffix(from reusedPromptTokenCount: Int) -> MLXPreparedInput {
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

// @_spi(Testing): see MLXPreparedInput.
@_spi(Testing) public struct MLXPromptCache: @unchecked Sendable {
    public let value: [any KVCache]

    public init(_ value: [any KVCache]) {
        self.value = value
    }
}

// @_spi(Testing): see MLXPreparedInput.
@_spi(Testing) public struct SendableChatMessages: @unchecked Sendable {
    public let value: [Chat.Message]

    public init(_ value: [Chat.Message]) {
        self.value = value
    }
}

/// Abstraction over `ModelContainer` so `MLXBackend` can be tested without real hardware.
///
/// `LMInput` and `[KVCache]` are wrapped so `MLXBackend` can own prompt preparation,
/// cache creation, prefix reuse, and token streaming while the concrete
/// `ModelContainer` conformance keeps the underlying MLX types off the public API.
// @_spi(Testing): published so backend test targets can stub the container
// (MockMLXModelContainer) without @testable access — companion split, #1749.
@_spi(Testing) public protocol MLXModelContainerProtocol: Sendable {
    func prepare(messages: [[String: String]]) async throws -> MLXPreparedInput
    func prepare(chat: SendableChatMessages) async throws -> MLXPreparedInput
    func makeCache(parameters: GenerateParameters) async throws -> MLXPromptCache
    func generate(
        input: MLXPreparedInput,
        cache: MLXPromptCache?,
        parameters: GenerateParameters
    ) async throws -> AsyncStream<Generation>
}

@_spi(Testing) extension ModelContainer: MLXModelContainerProtocol {
    public func prepare(messages: [[String: String]]) async throws -> MLXPreparedInput {
        let input = try await prepare(input: .init(messages: messages))
        return MLXPreparedInput(input)
    }

    public func prepare(chat: SendableChatMessages) async throws -> MLXPreparedInput {
        try await perform(nonSendable: chat.value) { context, chat in
            let input = try await context.processor.prepare(input: .init(chat: chat))
            return MLXPreparedInput(input)
        }
    }

    public func makeCache(parameters: GenerateParameters) async throws -> MLXPromptCache {
        await perform { context in
            MLXPromptCache(context.model.newCache(parameters: parameters))
        }
    }

    public func generate(
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
