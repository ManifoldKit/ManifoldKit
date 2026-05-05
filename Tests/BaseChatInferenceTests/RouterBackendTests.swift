import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

/// Tests for ``RouterBackend`` and ``GenerationConfig.requiredCapabilities``.
final class RouterBackendTests: XCTestCase {

    // MARK: - Fixtures

    /// Capabilities for a small backend that cannot do tools, structured
    /// output, thinking, or grammar — represents a tiny local model.
    private func minimalCaps(maxContext: Int32 = 2048) -> BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: maxContext,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            supportsThinking: false,
            streamsToolCallArguments: false,
            supportsParallelToolCalls: false
        )
    }

    /// Capabilities for a large backend that supports tool calling, JSON mode,
    /// thinking, and a wide context — represents a frontier remote model.
    private func capableCaps(maxContext: Int32 = 32_000) -> BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: maxContext,
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            supportsNativeJSONMode: true,
            supportsThinking: true,
            streamsToolCallArguments: true,
            supportsParallelToolCalls: true
        )
    }

    private func loaded(_ caps: BackendCapabilities) -> MockInferenceBackend {
        let mock = MockInferenceBackend(capabilities: caps)
        mock.isModelLoaded = true
        return mock
    }

    private func consumeAll(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }
        return events
    }

    // MARK: - GenerationCapabilityRequirement satisfies()

    func test_satisfies_toolCalling_matchesFlag() {
        XCTAssertTrue(capableCaps().satisfies(.toolCalling))
        XCTAssertFalse(minimalCaps().satisfies(.toolCalling))
    }

    func test_satisfies_minContextTokens_acceptsAtThreshold() {
        let caps = minimalCaps(maxContext: 4096)
        XCTAssertTrue(caps.satisfies(.minContextTokens(4096)))
        XCTAssertTrue(caps.satisfies(.minContextTokens(2000)))
        XCTAssertFalse(caps.satisfies(.minContextTokens(8000)))
    }

    func test_satisfies_setRequiresAllRequirements() {
        let caps = capableCaps()
        XCTAssertTrue(caps.satisfies([.toolCalling, .thinking]))
        XCTAssertFalse(minimalCaps().satisfies([.toolCalling, .thinking]))
    }

    func test_unsatisfied_listsOnlyMissingRequirements() {
        let unmet = minimalCaps().unsatisfied(from: [.toolCalling, .minContextTokens(1000)])
        // 2048 >= 1000 → minContextTokens satisfied; toolCalling missing.
        XCTAssertEqual(unmet, [.toolCalling])
    }

    // MARK: - GenerationConfig

    func test_generationConfig_requiredCapabilities_defaultsEmpty() {
        let config = GenerationConfig()
        XCTAssertTrue(config.requiredCapabilities.isEmpty)
    }

    func test_generationConfig_requiredCapabilities_propagates() {
        let config = GenerationConfig(requiredCapabilities: [.toolCalling, .thinking])
        XCTAssertEqual(config.requiredCapabilities, [.toolCalling, .thinking])
    }

    func test_generationConfig_codable_roundTripsRequiredCapabilities() throws {
        let original = GenerationConfig(requiredCapabilities: [.toolCalling, .minContextTokens(8000)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)
        XCTAssertEqual(decoded.requiredCapabilities, original.requiredCapabilities)
    }

    func test_generationConfig_codable_olderPayloadsDecodeToEmptySet() throws {
        // Older serialised configs lack the field entirely; the decoder must
        // tolerate the absence rather than failing. Build the legacy payload by
        // encoding a default config and stripping `requiredCapabilities`.
        let defaultEncoded = try JSONEncoder().encode(GenerationConfig())
        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: defaultEncoded) as? [String: Any]
        )
        dict.removeValue(forKey: "requiredCapabilities")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: stripped)
        XCTAssertTrue(decoded.requiredCapabilities.isEmpty)
    }

    // MARK: - RouterBackend.selectBackend

    func test_selectBackend_emptyRequirements_picksFirstChild() {
        let small = loaded(minimalCaps())
        let large = loaded(capableCaps())
        let router = RouterBackend(children: [small, large])
        XCTAssertTrue(router.selectBackend(for: []) === small)
    }

    func test_selectBackend_picksFirstSatisfyingChildInOrder() {
        let small = loaded(minimalCaps())
        let large = loaded(capableCaps())
        let router = RouterBackend(children: [small, large])
        let chosen = router.selectBackend(for: [.toolCalling])
        XCTAssertTrue(chosen === large)
    }

    func test_selectBackend_returnsNilWhenNoChildSatisfies() {
        let small = loaded(minimalCaps())
        let other = loaded(minimalCaps(maxContext: 1024))
        let router = RouterBackend(children: [small, other])
        XCTAssertNil(router.selectBackend(for: [.toolCalling]))
    }

    func test_selectBackend_prefersLoadedChildOverUnloadedSatisfier() {
        // Unloaded large is listed first; the loaded second-place child should
        // win so callers don't get routed to a backend that will immediately
        // fail with "no model loaded".
        let unloadedLarge = MockInferenceBackend(capabilities: capableCaps())
        unloadedLarge.isModelLoaded = false
        let loadedLarge = loaded(capableCaps())
        let router = RouterBackend(children: [unloadedLarge, loadedLarge])
        XCTAssertTrue(router.selectBackend(for: [.toolCalling]) === loadedLarge)
    }

    func test_selectBackend_fallsBackToUnloadedWhenNoLoadedChildSatisfies() {
        // Only an unloaded child can satisfy — pick it so the failure surfaces
        // as a load-time error from the backend rather than an opaque routing nil.
        let loadedSmall = loaded(minimalCaps())
        let unloadedLarge = MockInferenceBackend(capabilities: capableCaps())
        unloadedLarge.isModelLoaded = false
        let router = RouterBackend(children: [loadedSmall, unloadedLarge])
        XCTAssertTrue(router.selectBackend(for: [.toolCalling]) === unloadedLarge)
    }

    // MARK: - RouterBackend.generate dispatch

    func test_generate_dispatchesToFirstSatisfyingChild() async throws {
        let small = loaded(minimalCaps())
        small.tokensToYield = ["small"]
        let large = loaded(capableCaps())
        large.tokensToYield = ["large"]
        let router = RouterBackend(children: [small, large])

        let stream = try router.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig(requiredCapabilities: [.toolCalling])
        )
        let events = try await consumeAll(stream)

        XCTAssertEqual(small.generateCallCount, 0)
        XCTAssertEqual(large.generateCallCount, 1)
        XCTAssertEqual(events, [.token("large")])
    }

    func test_generate_emptyRequirements_picksFirstChildEvenIfWeaker() async throws {
        let small = loaded(minimalCaps())
        small.tokensToYield = ["small"]
        let large = loaded(capableCaps())
        large.tokensToYield = ["large"]
        let router = RouterBackend(children: [small, large])

        let stream = try router.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        let events = try await consumeAll(stream)

        XCTAssertEqual(small.generateCallCount, 1)
        XCTAssertEqual(large.generateCallCount, 0)
        XCTAssertEqual(events, [.token("small")])
    }

    func test_generate_throwsWhenNoChildSatisfies() throws {
        let small = loaded(minimalCaps())
        let other = loaded(minimalCaps())
        let router = RouterBackend(children: [small, other])
        let config = GenerationConfig(requiredCapabilities: [.toolCalling, .thinking])

        XCTAssertThrowsError(
            try router.generate(prompt: "hi", systemPrompt: nil, config: config)
        ) { error in
            guard case let InferenceError.noBackendSatisfiesRequirements(unmet) = error else {
                XCTFail("expected .noBackendSatisfiesRequirements, got \(error)")
                return
            }
            XCTAssertEqual(Set(unmet), [.toolCalling, .thinking])
        }
        XCTAssertEqual(small.generateCallCount, 0)
        XCTAssertEqual(other.generateCallCount, 0)
    }

    func test_generate_satisfiableBetweenChildren_butNoSingleChildSatisfies_throws() throws {
        // Child A has tool calling but small context; Child B has wide context
        // but no tool calling. A request asking for both must fail — the router
        // does not split a single request across children.
        let toolBackend = loaded(BackendCapabilities(
            maxContextTokens: 1024,
            supportsToolCalling: true
        ))
        let wideBackend = loaded(BackendCapabilities(
            maxContextTokens: 32_000,
            supportsToolCalling: false
        ))
        let router = RouterBackend(children: [toolBackend, wideBackend])
        let config = GenerationConfig(requiredCapabilities: [
            .toolCalling,
            .minContextTokens(8000)
        ])
        XCTAssertThrowsError(
            try router.generate(prompt: "hi", systemPrompt: nil, config: config)
        )
    }

    // MARK: - Lifecycle fan-out

    func test_stopGeneration_fansOutToAllChildren() {
        let a = loaded(minimalCaps())
        let b = loaded(capableCaps())
        let router = RouterBackend(children: [a, b])
        router.stopGeneration()
        XCTAssertEqual(a.stopCallCount, 1)
        XCTAssertEqual(b.stopCallCount, 1)
    }

    func test_unloadModel_fansOutToAllChildren() {
        let a = loaded(minimalCaps())
        let b = loaded(capableCaps())
        let router = RouterBackend(children: [a, b])
        router.unloadModel()
        XCTAssertEqual(a.unloadCallCount, 1)
        XCTAssertEqual(b.unloadCallCount, 1)
        XCTAssertFalse(router.isModelLoaded)
    }

    func test_resetConversation_fansOutToAllChildren() {
        let a = loaded(minimalCaps())
        let b = loaded(capableCaps())
        let router = RouterBackend(children: [a, b])
        router.resetConversation()
        XCTAssertEqual(a.resetConversationCallCount, 1)
        XCTAssertEqual(b.resetConversationCallCount, 1)
    }

    func test_loadModel_throws_loadingIsNotARoutingDecision() async {
        let a = loaded(minimalCaps())
        let router = RouterBackend(children: [a])
        do {
            try await router.loadModel(from: URL(fileURLWithPath: "/dev/null"), plan: ModelLoadPlan.testStub())
            XCTFail("expected throw")
        } catch let InferenceError.inferenceFailure(message) {
            XCTAssertTrue(message.contains("RouterBackend"))
        } catch {
            XCTFail("expected InferenceError.inferenceFailure, got \(error)")
        }
    }

    // MARK: - Capability union

    func test_capabilities_unionsToolCallingFlags() {
        let small = loaded(minimalCaps())
        let large = loaded(capableCaps())
        let router = RouterBackend(children: [small, large])
        XCTAssertTrue(router.capabilities.supportsToolCalling)
        XCTAssertTrue(router.capabilities.supportsThinking)
    }

    func test_capabilities_unionsGuidedStructuredOutputFlags() {
        let guidedOnly = loaded(BackendCapabilities(supportsGuidedStructuredOutput: true))
        let plain = loaded(minimalCaps())
        let router = RouterBackend(children: [plain, guidedOnly])

        XCTAssertTrue(router.capabilities.supportsGuidedStructuredOutput)
        XCTAssertEqual(router.capabilities.preferredStructuredOutputSupport, .guidedGeneration)
    }

    func test_capabilities_takesMaxContext() {
        let small = loaded(minimalCaps(maxContext: 2048))
        let large = loaded(capableCaps(maxContext: 32_000))
        let router = RouterBackend(children: [small, large])
        XCTAssertEqual(router.capabilities.maxContextTokens, 32_000)
    }
}
