import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

/// Tests for #482: ``GenerationQueue`` must thread
/// ``StructuredMessage`` (carrying ``MessagePart`` content including
/// thinking signatures) through to the backend boundary instead of
/// flattening to `(role, content)` strings.
@MainActor
final class GenerationQueueStructuredHistoryTests: XCTestCase {

    private var provider: FakeGenerationContextProvider!
    private var coordinator: GenerationQueue!

    override func setUp() async throws {
        try await super.setUp()
        provider = FakeGenerationContextProvider()
        coordinator = GenerationQueue()
        coordinator.provider = provider
    }

    override func tearDown() async throws {
        await coordinator?.stopGenerationAndWait()
        coordinator = nil
        provider = nil
        try await super.tearDown()
    }

    // MARK: - 1. Structured messages reach the backend's StructuredHistoryReceiver

    func test_generate_structuredMessages_reachStructuredReceiver() async throws {
        let signature = "sig_load_bearing"
        let history: [StructuredMessage] = [
            StructuredMessage(role: "user", content: "Q1"),
            StructuredMessage(role: "assistant", parts: [
                .thinking("internal reasoning", signature: signature),
                .text("answer"),
            ]),
            StructuredMessage(role: "user", content: "Q2"),
        ]

        let stream = try coordinator.generate(structuredMessages: history)
        for try await _ in stream.events {}

        let observed = try XCTUnwrap(provider.backend.lastReceivedStructuredHistory,
            "Coordinator must invoke setStructuredHistory(...) on backends conforming to StructuredHistoryReceiver")
        XCTAssertEqual(observed.count, 3)
        XCTAssertEqual(observed[1].parts.count, 2)
        XCTAssertEqual(observed[1].parts[0].thinkingContent, "internal reasoning")
        XCTAssertEqual(observed[1].parts[0].thinkingSignature, signature,
            "Signature must survive the trip from caller through coordinator to backend without being stripped")

        // Sabotage check: removing `installHistory(...)`'s
        // StructuredHistoryReceiver branch leaves
        // lastReceivedStructuredHistory == nil and the XCTUnwrap above
        // fails, surfacing a clear regression message.
    }

    // MARK: - 2. (role, content) entry still flattens to ConversationHistoryReceiver

    func test_generate_legacyTupleEntry_setsBothFlattenedAndStructured() async throws {
        let stream = try coordinator.generate(messages: [
            ("user", "hello"),
            ("assistant", "hi"),
            ("user", "how are you?"),
        ])
        for try await _ in stream.events {}

        // The legacy entry wraps each (role, content) into a single-text
        // StructuredMessage and threads through the same pipeline. Both
        // receiver protocols see the data so backends can pick whichever
        // shape they prefer.
        let structured = try XCTUnwrap(provider.backend.lastReceivedStructuredHistory)
        XCTAssertEqual(structured.count, 3)
        XCTAssertEqual(structured[0].textContent, "hello")

        let flattened = try XCTUnwrap(provider.backend.lastReceivedHistory)
        XCTAssertEqual(flattened.count, 3)
        XCTAssertEqual(flattened[0].role, "user")
        XCTAssertEqual(flattened[0].content, "hello")
    }

    // MARK: - 3. Flattened history drops thinking content

    /// Backends that only conform to ``ConversationHistoryReceiver`` (every
    /// non-Anthropic cloud / local backend today) get the flattened form.
    /// Thinking parts must be excluded from that flattening so prompt text
    /// doesn't leak provider-internal reasoning into requests that don't
    /// support replayed thinking.
    func test_flatten_dropsThinking_keepsTextOnly() async throws {
        let history: [StructuredMessage] = [
            StructuredMessage(role: "assistant", parts: [
                .thinking("hidden reasoning", signature: "sig"),
                .text("visible part"),
            ]),
        ]

        let stream = try coordinator.generate(structuredMessages: history)
        for try await _ in stream.events {}

        let flattened = try XCTUnwrap(provider.backend.lastReceivedHistory)
        XCTAssertEqual(flattened[0].content, "visible part",
            "Flattened history must contain only the visible text content — thinking is dropped")
        XCTAssertFalse(flattened[0].content.contains("hidden reasoning"),
            "Thinking content must never appear in the flattened (role, content) form")
    }

    // MARK: - 4. enqueue threads structured form through the queue

    func test_enqueue_structuredMessages_propagateToBackend() async throws {
        let history: [StructuredMessage] = [
            StructuredMessage(role: "user", parts: [.text("hello")]),
            StructuredMessage(role: "assistant", parts: [
                .thinking("think", signature: "sig_q"),
                .text("hi"),
            ]),
            StructuredMessage(role: "user", parts: [.text("again")]),
        ]
        let (_, stream) = try coordinator.enqueue(structuredMessages: history)
        for try await _ in stream.events {}

        let observed = try XCTUnwrap(provider.backend.lastReceivedStructuredHistory)
        XCTAssertEqual(observed.count, 3)
        XCTAssertEqual(observed[1].parts.first?.thinkingSignature, "sig_q",
            "Signatures must round-trip through the queue → tool-dispatch loop → backend without loss")
    }

    func test_generate_imageHistory_withVisionCapability_preservesStructuredImageParts() async throws {
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(supportsVision: true))
        provider = FakeGenerationContextProvider(backend: backend)
        coordinator.provider = provider

        let image = MessagePart.image(data: ImageFixtures.oneByOnePNGData, mimeType: "image/png")
        let history: [StructuredMessage] = [
            StructuredMessage(role: "user", parts: [
                .text("describe"),
                image,
            ])
        ]

        let stream = try coordinator.generate(structuredMessages: history)
        for try await _ in stream.events {}

        XCTAssertEqual(backend.lastReceivedStructuredHistory?.first?.parts, [.text("describe"), image])
        XCTAssertEqual(backend.lastReceivedHistory?.first?.content, "describe")
    }

    func test_generate_imageHistory_withoutVisionCapability_throws() {
        let history: [StructuredMessage] = [
            StructuredMessage(role: "user", parts: [
                .text("describe"),
                .image(data: ImageFixtures.oneByOnePNGData, mimeType: "image/png"),
            ])
        ]

        XCTAssertThrowsError(try coordinator.generate(structuredMessages: history)) { error in
            guard case InferenceError.inferenceFailure(let message) = error else {
                return XCTFail("Expected image capability failure, got \(error)")
            }
            XCTAssertTrue(message.contains("vision-capable backend"))
        }
    }
}
