import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

/// Tests that the off-main wrappers added in Phase 1.2 sub-step 4
/// (`capabilitiesAsync`, `tokenizerAsync`, `enqueueAsync`, `cancelAsync`)
/// are callable from non-`@MainActor` contexts without forcing every
/// caller to manually hop to the main actor.
///
/// The class itself is intentionally **not** annotated `@MainActor` —
/// each test method runs on the cooperative thread pool. The wrapper
/// implementation hops to main internally; if a wrapper accidentally
/// loses its `nonisolated` annotation (e.g. by removing the keyword in a
/// future refactor), these tests fail to compile, which is the contract
/// we want to lock in.
final class InferenceServiceNonisolatedTests: XCTestCase {

    // MARK: - capabilitiesAsync

    func test_capabilitiesAsync_returnsValueFromOffMain() async throws {
        let backend = CapabilityBackend()
        let service = try await makeLoadedService(backend: backend)

        let caps = await service.capabilitiesAsync()

        XCTAssertEqual(caps?.maxContextTokens, 4096)
        XCTAssertEqual(caps?.supportsSystemPrompt, true)
    }

    func test_capabilitiesAsync_isNilWhenNoBackendLoaded() async {
        let service = InferenceService()

        let caps = await service.capabilitiesAsync()

        XCTAssertNil(caps)
    }

    // MARK: - tokenizerAsync

    func test_tokenizerAsync_returnsBackendTokenizerFromOffMain() async throws {
        let backend = TokenizerVendingBackend()
        let service = try await makeLoadedService(backend: backend)

        let tokenizer = await service.tokenizerAsync()

        XCTAssertNotNil(tokenizer)
        // Off-main use: tokenizer is `Sendable`, so we can call it directly here.
        XCTAssertEqual(tokenizer?.tokenCount("hello world"), 11)
    }

    func test_tokenizerAsync_isNilWhenBackendDoesNotVendOne() async throws {
        let backend = CapabilityBackend()
        let service = try await makeLoadedService(backend: backend)

        let tokenizer = await service.tokenizerAsync()

        XCTAssertNil(tokenizer)
    }

    // MARK: - enqueueAsync

    func test_enqueueAsync_drivesGenerationFromOffMain() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello", " ", "off-main"]
        let service = try await makeLoadedService(backend: mock)

        let (_, stream) = try await service.enqueueAsync(
            structuredMessages: [StructuredMessage(role: "user", content: "hi")]
        )

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { tokens.append(t) }
        }

        XCTAssertEqual(tokens, ["Hello", " ", "off-main"])
        let stillGenerating = await MainActor.run { service.isGenerating }
        XCTAssertFalse(stillGenerating)
    }

    func test_enqueueAsync_concurrentCallersDoNotRace() async throws {
        // Three off-main callers issue enqueue concurrently. The queue's
        // sequential FIFO guarantee says streams complete in order, and no
        // call must fail to enqueue. The point of the test is that crossing
        // the actor boundary three times in parallel still respects the
        // serialization the @MainActor coordinator provides — i.e. the
        // wrapper does not introduce a race that the synchronous
        // surface didn't have.
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["x"]
        let service = try await makeLoadedService(backend: mock)

        async let one = service.enqueueAsync(
            structuredMessages: [StructuredMessage(role: "user", content: "1")]
        )
        async let two = service.enqueueAsync(
            structuredMessages: [StructuredMessage(role: "user", content: "2")]
        )
        async let three = service.enqueueAsync(
            structuredMessages: [StructuredMessage(role: "user", content: "3")]
        )

        let results = try await [one, two, three]
        XCTAssertEqual(results.count, 3)

        // Drain every stream so the queue auto-drains and the subsequent
        // assertion sees the post-completion state.
        for (_, stream) in results {
            for try await _ in stream.events {}
        }

        let stillGenerating = await MainActor.run { service.isGenerating }
        XCTAssertFalse(stillGenerating)
    }

    // MARK: - cancelAsync

    func test_cancelAsync_cancelsActiveRequestFromOffMain() async throws {
        let gated = GatedTestBackend()
        let service = try await makeLoadedService(backend: gated)

        let (token, stream) = try await service.enqueueAsync(
            structuredMessages: [StructuredMessage(role: "user", content: "hi")]
        )

        // Wait until generation is actually active before cancelling so we
        // exercise the active-request path rather than the queued-removal
        // path.
        let started = expectation(description: "generation started")
        Task { @MainActor in
            while !service.isGenerating { await Task.yield() }
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)

        await service.cancelAsync(token)

        // Drain whatever remains. After cancel the stream terminates with
        // either a finish or a thrown error; either is acceptable — we
        // just need to confirm `isGenerating` flips back to false.
        do {
            for try await _ in stream.events {}
        } catch {
            // Expected when cancellation propagates through the stream.
        }

        let stillGenerating = await MainActor.run { service.isGenerating }
        XCTAssertFalse(stillGenerating)
    }

    // MARK: - Coexistence with @MainActor surface

    @MainActor
    func test_existingMainActorCallers_stillWork() async throws {
        // The @MainActor synchronous accessors must still compile and work
        // unchanged — the new wrappers are purely additive.
        let backend = CapabilityBackend()
        let service = InferenceService(backend: backend, name: "Mock")

        XCTAssertEqual(service.capabilities?.maxContextTokens, 4096)
        XCTAssertNil(service.tokenizer)
        XCTAssertTrue(service.isModelLoaded)
    }

    // MARK: - Helpers

    /// Builds an `InferenceService` and loads it through the public load
    /// path on the main actor.
    ///
    /// The `#if DEBUG` `init(backend:)` debug helper does not survive
    /// the off-main reference round-trip cleanly here — `weak var provider`
    /// inside `GenerationCoordinator` ends up nil by the time enqueue runs
    /// from a non-MainActor context. The supported off-main composition
    /// path is to construct via the nonisolated `init()` and load through
    /// the registered factory, which is exactly what runtime use cases
    /// will do.
    private func makeLoadedService(backend: any InferenceBackend) async throws -> InferenceService {
        let service = InferenceService()
        await MainActor.run {
            service.registerBackendFactory { _ in backend }
            service.declareSupport(for: .gguf)
        }
        try await service.loadModel(from: ModelInfo(
            name: "Test",
            fileName: "Test.bin",
            url: URL(fileURLWithPath: "/Test.bin"),
            fileSize: 0,
            modelType: .gguf
        ))
        return service
    }
}

// MARK: - Test Backends

private final class CapabilityBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    func unloadModel() {
        isModelLoaded = false
    }

    func stopGeneration() {
        isGenerating = false
    }
}

/// Backend that vends a tokenizer via ``TokenizerVendor``.
private final class TokenizerVendingBackend: InferenceBackend, TokenizerVendor, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 2048,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var tokenizer: any TokenizerProvider { CountingTokenizer() }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    func unloadModel() {
        isModelLoaded = false
    }

    func stopGeneration() {
        isGenerating = false
    }
}

private struct CountingTokenizer: TokenizerProvider {
    func tokenCount(_ text: String) -> Int { text.count }
}

/// A backend whose stream we can hold open until cancellation arrives,
/// so we can exercise the active-request cancel path through `cancelAsync`.
private final class GatedTestBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    private var continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        isGenerating = true
        let stream = AsyncThrowingStream<GenerationEvent, Error> { [weak self] continuation in
            self?.continuation = continuation
        }
        return GenerationStream(stream)
    }

    func unloadModel() {
        continuation?.finish()
        continuation = nil
        isModelLoaded = false
    }

    func stopGeneration() {
        continuation?.finish()
        continuation = nil
        isGenerating = false
    }
}
