import XCTest
@testable import BaseChatInference

#if AnyLanguageModel
import AnyLanguageModel
@testable import BaseChatAnyLanguageModelBridge

final class AnyLanguageModelBackendTests: XCTestCase {
    func test_generate_streamsTextDeltas() async throws {
        let backend = AnyLanguageModelBackend { _ in
            AnyLanguageModelDescriptor(
                model: MockLanguageModel(chunks: ["Hello", "Hello world"]),
                capabilities: AnyLanguageModelBridgeCapabilities.remote(maxContextTokens: 2_048, maxOutputTokens: 128)
            )
        }
        try await backend.loadModel(from: URL(string: "openai://gpt-4o?apiKey=test")!, plan: makePlan(context: 2_048))

        let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig(maxOutputTokens: 32))
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }

        XCTAssertEqual(events, [.token("Hello"), .token(" world")])
        XCTAssertFalse(backend.isGenerating)
    }

    func test_generate_rejectsToolCallingConfig() async throws {
        let backend = AnyLanguageModelBackend { _ in
            AnyLanguageModelDescriptor(
                model: MockLanguageModel(chunks: ["done"]),
                capabilities: AnyLanguageModelBridgeCapabilities.remote()
            )
        }
        try await backend.loadModel(from: URL(string: "openai://gpt-4o?apiKey=test")!, plan: makePlan(context: 1_024))

        let config = GenerationConfig(tools: [ToolDefinition(name: "weather", description: "desc", parameters: .object([:]))])

        do {
            _ = try backend.generate(prompt: "Hi", systemPrompt: nil, config: config)
            XCTFail("Expected tool-calling config to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, AnyLanguageModelBridgeError.unsupportedToolCalling.localizedDescription)
        }
    }

    func test_urlResolver_buildsOpenAIResponsesDescriptor() throws {
        let descriptor = try AnyLanguageModelURLResolver.resolve(URL(string: "openai-responses://gpt-4.1?apiKey=test")!)
        XCTAssertEqual(descriptor.capabilities.memoryStrategy, .external)
        XCTAssertTrue(descriptor.capabilities.isRemote)
    }

    private func makePlan(context: Int) -> ModelLoadPlan {
        ModelLoadPlan(
            inputs: .init(
                modelFileSize: 0,
                memoryStrategy: .external,
                requestedContextSize: context,
                trainedContextLength: nil,
                kvBytesPerToken: 0,
                availableMemoryBytes: 0,
                physicalMemoryBytes: 0,
                absoluteContextCeiling: context,
                headroomFraction: 0
            ),
            outcome: .init(
                effectiveContextSize: context,
                estimatedResidentBytes: 0,
                estimatedKVBytes: 0,
                totalEstimatedBytes: 0,
                verdict: .allow,
                reasons: []
            )
        )
    }
}

private struct MockLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let chunks: [String]

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content : Generable {
        let final = chunks.last ?? ""
        return LanguageModelSession.Response(
            content: final as! Content,
            rawContent: GeneratedContent(final),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content : Generable {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            for chunk in chunks {
                continuation.yield(
                    LanguageModelSession.ResponseStream<Content>.Snapshot(
                        content: (chunk as! Content).asPartiallyGenerated(),
                        rawContent: GeneratedContent(chunk)
                    )
                )
            }
            continuation.finish()
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}
#endif
