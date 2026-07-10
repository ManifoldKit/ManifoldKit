import XCTest
@testable import ManifoldInference

/// Verifies that ``GenerationQueue`` auto-folds
/// ``ToolSystemPromptBuilder/preferTools(for:)`` into the system prompt for
/// prompt-template backends whose template does **not** render tools natively
/// (#1856), and that it does *not* double-inject for `.gemma4` (which renders a
/// native `<|tool>` block) or inject at all when there are no tools / no
/// tool-calling support.
///
/// These exercise the exact-preflight (`TokenCountingBackend`) dispatch path —
/// the one local GGUF models actually take — so the assembled prompt that
/// reaches the backend is captured in `lastPrompt`.
@MainActor
final class GenerationQueueToolSystemPromptTests: XCTestCase {

    private func tool(_ name: String) -> ToolDefinition {
        ToolDefinition(name: name, description: "Gets \(name)", parameters: .object([:]))
    }

    /// The canonical preamble headline `ToolSystemPromptBuilder.preferTools`
    /// emits for `.standard` — used to detect injection without coupling the
    /// test to the full multi-line phrasing.
    private let preambleMarker = "You have the following tools available:"

    private func makeBackend(
        template: PromptTemplate,
        supportsToolCalling: Bool,
        chatTemplateRaw: String? = nil
    ) -> (backend: ToolPromptCountingBackend, provider: ToolPromptFakeProvider, queue: GenerationQueue) {
        let backend = ToolPromptCountingBackend(supportsToolCalling: supportsToolCalling)
        // Always-fits: one count under budget so generate runs without trimming.
        backend.countTokensResponses = [10]
        let provider = ToolPromptFakeProvider(backend: backend)
        provider.promptTemplate = template
        provider.chatTemplateRaw = chatTemplateRaw
        let queue = GenerationQueue()
        provider.bind(to: queue)
        return (backend, provider, queue)
    }

    // (a) Non-Gemma template + tools → preamble folded into the prompt.
    func test_nonGemmaTemplate_withTools_injectsPreamble() async throws {
        let (backend, provider, queue) = makeBackend(template: .llama3, supportsToolCalling: true)

        let (_, stream) = try queue.enqueue(structuredMessages: [StructuredMessage(role: "user", content: "what time is it?")], systemPrompt: "You are a helpful assistant.", config: GenerationConfig(tools: [tool("get_time")]))
        for try await _ in stream.events {}

        let prompt = try XCTUnwrap(backend.lastPrompt)
        XCTAssertTrue(prompt.contains(preambleMarker),
                      "non-native template must get the tool preamble folded in")
        XCTAssertTrue(prompt.contains("get_time"),
                      "the tool name must appear in the rendered preamble")
        XCTAssertTrue(prompt.contains("You are a helpful assistant."),
                      "the host system prompt must survive alongside the preamble")
        withExtendedLifetime(provider) {}
    }

    // (b) Gemma 4 renders tools natively → preamble must NOT be injected.
    func test_gemma4Template_withTools_doesNotInjectPreamble() async throws {
        let (backend, provider, queue) = makeBackend(template: .gemma4, supportsToolCalling: true)

        let (_, stream) = try queue.enqueue(structuredMessages: [StructuredMessage(role: "user", content: "what time is it?")], systemPrompt: "You are a helpful assistant.", config: GenerationConfig(tools: [tool("get_time")]))
        for try await _ in stream.events {}

        let prompt = try XCTUnwrap(backend.lastPrompt)
        XCTAssertFalse(prompt.contains(preambleMarker),
                       "gemma4 renders tools natively — the system-prompt preamble must not double-inject")
        // Sanity: the native block still carries the tool (so we know tools
        // weren't simply dropped — they reached the model the native way).
        XCTAssertTrue(prompt.contains("<|tool>"),
                      "gemma4 must still emit its native tool block")
        withExtendedLifetime(provider) {}
    }

    // (c1) No tools → no injection regardless of template.
    func test_nonGemmaTemplate_noTools_noInjection() async throws {
        let (backend, provider, queue) = makeBackend(template: .llama3, supportsToolCalling: true)

        let (_, stream) = try queue.enqueue(structuredMessages: [StructuredMessage(role: "user", content: "hi")], systemPrompt: "You are a helpful assistant.", config: GenerationConfig())
        for try await _ in stream.events {}

        let prompt = try XCTUnwrap(backend.lastPrompt)
        XCTAssertFalse(prompt.contains(preambleMarker),
                       "empty tools → nothing to inject")
        withExtendedLifetime(provider) {}
    }

    // (c2) Backend doesn't support tool calling → tools are rejected before
    // dispatch, so no injection can occur. (The queue throws on enqueue, which
    // is the established contract for tools-on-incapable-backends.)
    func test_toolUnsupportedBackend_withTools_rejectsAndDoesNotInject() async throws {
        let (backend, provider, queue) = makeBackend(template: .llama3, supportsToolCalling: false)

        do {
            _ = try queue.enqueue(structuredMessages: [StructuredMessage(role: "user", content: "hi")], systemPrompt: "You are a helpful assistant.", config: GenerationConfig(tools: [tool("get_time")]))
            XCTFail("enqueue must reject tools on a backend that can't call them")
        } catch {
            // Expected: the queue refuses tools on an incapable backend.
        }

        XCTAssertNil(backend.lastPrompt,
                     "rejected request must never reach the backend, so nothing is injected")
        withExtendedLifetime(provider) {}
    }

    // (d) THE PRODUCTION FAIL-FAST (#1957 Tier 3 / #1909): an unrenderable
    // embedded chat template + tools requested must surface an *error through the
    // real generation path* — not silently drop the tools and ship a tool-less
    // prompt. This exercises the exact `GenerationQueue` → `PromptRenderer.render`
    // (throwing) route a local GGUF model takes, proving the fix is wired into
    // production and not merely present on the unit-level `render` API. The
    // `PromptRendererToolFidelityTests` cover the unit; this guards the seam.
    func test_productionPath_failsFast_onUnusableTemplateWithTools() async throws {
        // A template swift-jinja cannot parse → the embedded render always misses,
        // forcing the fail-fast since `.chatML` does not render tools natively.
        let (backend, provider, queue) = makeBackend(
            template: .chatML,
            supportsToolCalling: true,
            chatTemplateRaw: "{%- if broken"
        )

        let (_, stream) = try queue.enqueue(structuredMessages: [StructuredMessage(role: "user", content: "what time is it?")], systemPrompt: "You are a helpful assistant.", config: GenerationConfig(tools: [tool("get_time")]))

        var thrown: Error?
        do {
            for try await _ in stream.events {}
        } catch {
            thrown = error
        }

        let error = try XCTUnwrap(
            thrown,
            "the production generation path must surface an error when the embedded "
                + "template is unusable and tools were requested — not silently drop tools"
        )
        XCTAssertTrue(
            String(describing: error).contains("tool"),
            "the surfaced error must name the tool-fidelity failure; got: \(error)"
        )
        // The tool-less prompt must NOT have reached the backend.
        XCTAssertNil(
            backend.lastPrompt,
            "a fail-fast turn must abort before dispatching a tool-less prompt to the backend"
        )
        withExtendedLifetime(provider) {}
    }
}

// MARK: - Local mocks

/// A `TokenCountingBackend` with `requiresPromptTemplate = true` and a
/// configurable `supportsToolCalling`, so it exercises the exact-preflight
/// dispatch path and captures the assembled prompt.
private final class ToolPromptCountingBackend: InferenceBackend, TokenCountingBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities

    var tokensToYield: [String] = ["ok"]
    private(set) var lastPrompt: String?

    var countTokensResponses: [Int] = []
    private(set) var countTokensCalled = 0

    init(supportsToolCalling: Bool, contextSize: Int32 = 4096) {
        self.capabilities = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: contextSize,
            requiresPromptTemplate: true,
            supportsSystemPrompt: true,
            supportsToolCalling: supportsToolCalling,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: true
        )
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {}

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        lastPrompt = prompt
        let tokens = tokensToYield
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            Task {
                for token in tokens { continuation.yield(.token(token)) }
                continuation.finish()
            }
        }
        return GenerationStream(stream)
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false }

    func countTokens(_ text: String) throws -> Int {
        countTokensCalled += 1
        guard !countTokensResponses.isEmpty else { return 10 }
        let idx = min(countTokensCalled - 1, countTokensResponses.count - 1)
        return countTokensResponses[idx]
    }
}

@MainActor
private final class ToolPromptFakeProvider {
    let backend: ToolPromptCountingBackend
    var promptTemplate: PromptTemplate = .chatML
    var chatTemplateRaw: String?

    init(backend: ToolPromptCountingBackend) {
        self.backend = backend
        self.backend.isModelLoaded = true
    }

    func bind(to queue: GenerationQueue) {
        queue.bindContext(
            currentBackend: { [weak self] in self?.backend },
            isBackendLoaded: { [weak self] in self?.backend.isModelLoaded ?? false },
            selectedPromptTemplate: { [weak self] in self?.promptTemplate ?? .chatML },
            selectedChatTemplateRaw: { [weak self] in self?.chatTemplateRaw }
        )
    }
}
