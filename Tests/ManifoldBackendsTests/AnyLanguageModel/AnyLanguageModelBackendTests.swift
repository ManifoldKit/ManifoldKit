import XCTest
@testable import ManifoldInference

import AnyLanguageModel
import ManifoldAnyLanguageModel

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

    /// Regression test for arch-plan 1.3 / api-review-wave2 0.D:
    /// `loadModel` used to rebuild `BackendCapabilities` from a fresh
    /// literal, silently zeroing `supportsVision`, `supportsGuidedStructuredOutput`,
    /// `supportsStrictSchema`, `toolDialect`, `maxAdvertisedToolCount`,
    /// `rendersFullPrompt`, and `sharesMLXProcessResources` even when the
    /// resolved descriptor advertised non-default values for them. It now
    /// calls `updating(maxContextTokens:)`, which must preserve all seven.
    func test_loadModel_preservesFieldsThatWereFormerlyDroppedByFreshLiteralRebuild() async throws {
        let nonDefaultCapabilities = AnyLanguageModelBridgeCapabilities.remote().updating(
            supportsVision: true,
            supportsGuidedStructuredOutput: true,
            supportsStrictSchema: true,
            sharesMLXProcessResources: true,
            rendersFullPrompt: true,
            maxAdvertisedToolCount: .some(12),
            toolDialect: .some(ToolCallDialect(
                family: .mistral,
                openDelimiter: "[TOOL_CALLS]",
                closeDelimiter: nil,
                argEncoding: .json,
                extractability: .clean
            ))
        )

        let backend = AnyLanguageModelBackend { _ in
            AnyLanguageModelDescriptor(
                model: MockLanguageModel(chunks: ["done"]),
                capabilities: nonDefaultCapabilities
            )
        }
        try await backend.loadModel(from: URL(string: "openai://gpt-4o?apiKey=test")!, plan: makePlan(context: 4_096))

        let loaded = backend.capabilities
        // The one field this call site genuinely overrides.
        XCTAssertEqual(loaded.maxContextTokens, 4_096)
        // The seven fields the fresh-literal rebuild used to drop.
        XCTAssertTrue(loaded.supportsVision, "supportsVision was dropped")
        XCTAssertTrue(loaded.supportsGuidedStructuredOutput, "supportsGuidedStructuredOutput was dropped")
        XCTAssertTrue(loaded.supportsStrictSchema, "supportsStrictSchema was dropped")
        XCTAssertEqual(loaded.toolDialect?.family, .mistral, "toolDialect was dropped")
        XCTAssertEqual(loaded.maxAdvertisedToolCount, 12, "maxAdvertisedToolCount was dropped")
        XCTAssertTrue(loaded.rendersFullPrompt, "rendersFullPrompt was dropped")
        XCTAssertTrue(loaded.sharesMLXProcessResources, "sharesMLXProcessResources was dropped")
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
