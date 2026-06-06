import XCTest
@testable import ManifoldInference

#if AnyLanguageModel
import AnyLanguageModel
@testable import ManifoldBackends

/// Holds the AnyLanguageModel bridge to the same universal backend contract as
/// the native backends.
///
/// Two tiers:
///
/// 1. **Offline contract + capability mapping** — runs whenever the
///    `AnyLanguageModel` trait is enabled, with no network access. Exercises
///    the universal `InferenceBackend` invariants, the capability
///    meta-contract, and the fail-closed mapping between the advertised
///    `BackendCapabilities` and `generate()`'s actual behaviour.
///
/// 2. **Live provider conformance** — gated behind `RUN_ANYLM_E2E=1` plus an
///    `ANYLM_E2E_URL` bridge URL (for example
///    `gemini://gemini-2.0-flash?apiKey=…`). Skipped cleanly when either is
///    absent so the default suite never requires a key to compile or pass.
final class AnyLanguageModelConformanceTests: XCTestCase {

    private let backendName = "AnyLanguageModelBackend"

    // MARK: - Tier 1: offline universal contract

    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants(makingBackend: { AnyLanguageModelBackend() })
    }

    /// The bridge streams plain text only: it advertises the conservative
    /// capability floor (no tools / structured output / thinking) so the
    /// capability router never routes those requests to it. The meta-contract
    /// passes trivially because no tracked flag is declared `true`.
    func test_contract_capabilityMetaContract() {
        BackendContractChecks.resetCapabilityClaims(forBackend: backendName)
        BackendContractChecks.assertCapabilityMetaContract(
            backendName: backendName,
            capabilities: AnyLanguageModelBackend().capabilities
        )
    }

    // MARK: - Tier 1: capability mapping ↔ behaviour

    /// Confirms the advertised floor matches what `generate()` actually accepts.
    /// If a future change flips one of these flags `true` without wiring the
    /// behaviour, the capability router would misroute a request the bridge
    /// then rejects at runtime — this test pins the two in sync.
    func test_capabilityMapping_matchesFailClosedBehaviour() async throws {
        let caps = AnyLanguageModelBridgeCapabilities.remote()
        XCTAssertFalse(caps.supportsToolCalling, "bridge does not translate tool definitions")
        XCTAssertFalse(caps.supportsStructuredOutput, "bridge streams plain text only")
        XCTAssertFalse(caps.supportsNativeJSONMode, "bridge has no JSON mode")
        XCTAssertFalse(caps.supportsThinking, "bridge does not surface reasoning tokens")
        XCTAssertFalse(caps.supportsGrammarConstrainedSampling, "bridge exposes no grammar sampling")
        XCTAssertTrue(caps.isRemote, "bridge providers are reached over the network")
        XCTAssertTrue(caps.supportsStreaming)

        let backend = AnyLanguageModelBackend { _ in
            AnyLanguageModelDescriptor(
                model: ConformanceMockLanguageModel(chunks: ["ok"]),
                capabilities: AnyLanguageModelBridgeCapabilities.remote()
            )
        }
        try await backend.loadModel(from: URL(string: "openai://gpt-4o?apiKey=test")!, plan: makePlan(context: 1_024))

        // tools advertised false ⇒ generate must reject a tools config
        let tools = GenerationConfig(tools: [ToolDefinition(name: "t", description: "d", parameters: .object([:]))])
        XCTAssertThrowsError(try backend.generate(prompt: "hi", systemPrompt: nil, config: tools))

        // structured output advertised false ⇒ generate must reject jsonMode
        let json = GenerationConfig(jsonMode: true)
        XCTAssertThrowsError(try backend.generate(prompt: "hi", systemPrompt: nil, config: json))
    }

    // MARK: - Tier 2: live provider (env-gated)

    func test_live_streamsRealCompletion() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["RUN_ANYLM_E2E"] == "1", "Set RUN_ANYLM_E2E=1 to run AnyLanguageModel live conformance.")
        guard let urlString = env["ANYLM_E2E_URL"], let url = URL(string: urlString) else {
            throw XCTSkip("Set ANYLM_E2E_URL to a bridge URL (e.g. gemini://gemini-2.0-flash?apiKey=…).")
        }

        // Universal invariants hold against the live-configured backend too.
        BackendContractChecks.assertAllInvariants(makingBackend: { AnyLanguageModelBackend() })

        let backend = AnyLanguageModelBackend()
        try await backend.loadModel(from: url, plan: makePlan(context: 8_192))
        XCTAssertTrue(backend.isModelLoaded)

        let config = GenerationConfig(maxOutputTokens: 64)
        let stream = try backend.generate(
            prompt: "Reply with the single word: pong.",
            systemPrompt: "You are a terse test fixture.",
            config: config
        )

        var text = ""
        for try await event in stream.events {
            if case .token(let delta) = event { text += delta }
        }

        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "live provider produced no text")
        XCTAssertFalse(backend.isGenerating, "isGenerating must reset after the stream finishes")

        // The advertised capability floor must survive a real load — the router
        // reads these after the model is in memory.
        XCTAssertFalse(backend.capabilities.supportsToolCalling)
        XCTAssertFalse(backend.capabilities.supportsThinking)
    }

    // MARK: - Helpers

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

/// Minimal `LanguageModel` stub for the offline capability-mapping test. Named
/// distinctly from `AnyLanguageModelBackendTests`' private mock to avoid a
/// duplicate-symbol clash within the test target.
private struct ConformanceMockLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let chunks: [String]

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
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
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
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
