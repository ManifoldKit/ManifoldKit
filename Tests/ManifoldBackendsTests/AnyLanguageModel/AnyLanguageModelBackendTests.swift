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

    // MARK: - baseURL resolution (regression for the silent-fallback footgun)
    //
    // `AnyLanguageModelURLResolver.resolve` used to do
    // `URL(string: queryItems["baseURL"] ?? "") ?? vendorDefault` for every
    // provider: an absent `baseURL` correctly fell back to the vendor
    // default, but a *present-but-unparseable* one silently fell back too —
    // sending the caller's `apiKey` to the real vendor endpoint instead of
    // the (mistyped) host they configured. It must now throw instead.

    func test_urlResolver_absentBaseURL_usesVendorDefault() throws {
        let descriptor = try AnyLanguageModelURLResolver.resolve(URL(string: "openai://gpt-4o?apiKey=test")!)
        let model = try XCTUnwrap(descriptor.model as? OpenAILanguageModel)
        XCTAssertEqual(model.baseURL, OpenAILanguageModel.defaultBaseURL)
    }

    func test_urlResolver_validCustomBaseURL_isUsed() throws {
        let descriptor = try AnyLanguageModelURLResolver.resolve(
            URL(string: "openai://gpt-4o?apiKey=test&baseURL=https://my-proxy.example.com/v1/")!
        )
        let model = try XCTUnwrap(descriptor.model as? OpenAILanguageModel)
        XCTAssertEqual(model.baseURL, URL(string: "https://my-proxy.example.com/v1/"))
    }

    func test_urlResolver_malformedBaseURL_throwsRatherThanFallingBackToVendorDefault() throws {
        // A space in the host is not a valid URL under `URL(string:)`.
        var components = URLComponents(string: "openai://gpt-4o")!
        components.queryItems = [
            URLQueryItem(name: "apiKey", value: "super-secret-key"),
            URLQueryItem(name: "baseURL", value: "http://exa mple.com"),
        ]
        let url = try XCTUnwrap(components.url)

        XCTAssertThrowsError(try AnyLanguageModelURLResolver.resolve(url)) { error in
            guard case .invalidBaseURL(let raw, let provider) = error as? AnyLanguageModelBridgeError else {
                XCTFail("Expected .invalidBaseURL, got \(error)")
                return
            }
            XCTAssertEqual(raw, "http://exa mple.com")
            XCTAssertEqual(provider, "openai")
            // The error must never leak the caller's apiKey.
            XCTAssertFalse((error as? AnyLanguageModelBridgeError)?.errorDescription?.contains("super-secret-key") ?? true)
        }
    }

    func test_urlResolver_malformedBaseURL_throwsForAnthropicGeminiOllamaOpenResponses() throws {
        let schemesRequiringAPIKey: [(scheme: String, host: String)] = [
            ("anthropic", "claude-3"),
            ("gemini", "gemini-pro"),
            ("openresponses", "some-model"),
        ]
        for (scheme, host) in schemesRequiringAPIKey {
            var components = URLComponents(string: "\(scheme)://\(host)")!
            components.queryItems = [
                URLQueryItem(name: "apiKey", value: "test"),
                URLQueryItem(name: "baseURL", value: "http://exa mple.com"),
            ]
            let url = try XCTUnwrap(components.url)
            XCTAssertThrowsError(try AnyLanguageModelURLResolver.resolve(url), "scheme \(scheme) should throw") { error in
                XCTAssertTrue(error is AnyLanguageModelBridgeError)
                if case .invalidBaseURL = error as? AnyLanguageModelBridgeError {
                    // expected
                } else {
                    XCTFail("Expected .invalidBaseURL for scheme \(scheme), got \(error)")
                }
            }
        }

        // Ollama takes no apiKey.
        var ollamaComponents = URLComponents(string: "ollama://llama3")!
        ollamaComponents.queryItems = [
            URLQueryItem(name: "baseURL", value: "http://exa mple.com"),
        ]
        let ollamaURL = try XCTUnwrap(ollamaComponents.url)
        XCTAssertThrowsError(try AnyLanguageModelURLResolver.resolve(ollamaURL)) { error in
            if case .invalidBaseURL = error as? AnyLanguageModelBridgeError {
                // expected
            } else {
                XCTFail("Expected .invalidBaseURL for scheme ollama, got \(error)")
            }
        }
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
