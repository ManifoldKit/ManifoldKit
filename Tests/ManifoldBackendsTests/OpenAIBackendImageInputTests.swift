#if CloudSaaS
import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldCloud
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
#if Ollama
@testable import ManifoldOllama
#endif
#if CloudSaaS
@testable import ManifoldCloudSaaS
#endif
@testable import ManifoldCloudCore

/// Tests for #943 (part of #20): `image_url` content parts on the OpenAI
/// Chat Completions API.
///
/// `OpenAIBackend` must:
///
/// 1. Encode each ``MessagePart/image(data:mimeType:)`` part as an
///    `{"type":"image_url","image_url":{"url":"data:..."}}` content
///    part on the request body.
/// 2. Keep text-only turns collapsed to plain `content: "..."` so the
///    common-case wire shape stays minimal — the existing replay tests
///    assert on this exact form.
/// 3. Reject image attachments when the configured model isn't
///    vision-capable, with a clear local error.
/// 4. Advertise `supportsVision` based on the configured model name so
///    ``GenerationQueue``'s pre-flight matches the wire-level
///    behaviour.
/// 5. Conform to ``StructuredHistoryReceiver`` so the coordinator routes
///    `MessagePart.image` parts to it.
final class OpenAIBackendImageInputTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Builds a backend wired to a unique mock URL host. Each test gets its
    /// own UUID-stamped host so concurrent runs don't see each other's
    /// captured requests — `MockURLProtocol.reset()` is deliberately not
    /// called (it would race with parallel suites).
    private func makeBackend(
        modelName: String = "gpt-4o-mini"
    ) async throws -> (OpenAIBackend, URL) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = OpenAIBackend(urlSession: session)
        let url = URL(string: "https://openai-image-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-test", modelName: modelName)
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        return (backend, url)
    }

    private func sseStub(url: URL) {
        let chunk = Data(
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8
        )
        MockURLProtocol.stub(url: url, response: .sse(chunks: [chunk], statusCode: 200))
    }

    private func extractRequestJSON(host: String?) throws -> [String: Any] {
        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url?.host == host })
        // URLSession may convert httpBody → httpBodyStream during transmission.
        let body: Data
        if let direct = captured?.httpBody {
            body = direct
        } else if let stream = captured?.httpBodyStream {
            var data = Data()
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read > 0 { data.append(buffer, count: read) }
            }
            stream.close()
            body = data
        } else {
            throw NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "no body"])
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// 4-byte payload — the bytes are not a valid PNG, but the encoder
    /// doesn't decode the data, it only base64-encodes it. Using a tiny
    /// fixture keeps the test fast and the assertion exact.
    private func fixtureImage(_ marker: UInt8) -> Data {
        Data([0x89, 0x50, 0x4E, marker])
    }

    // MARK: - 1. Single image — promoted to content[] with image_url part

    func test_singleImage_emitsImageURLPartAfterText() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        let imageData = fixtureImage(0xAA)
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text("Describe this image."),
                .image(data: imageData, mimeType: "image/png"),
            ]),
        ])

        let stream = try backend.generate(prompt: "Describe this image.", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        let userContent = try XCTUnwrap(messages[0]["content"] as? [[String: Any]],
            "Image-bearing user turn must serialize as a content[] array, not a string")
        XCTAssertEqual(userContent.count, 2, "Expect one text part and one image_url part")

        XCTAssertEqual(userContent[0]["type"] as? String, "text",
            "Text part comes first — matches OpenAI's vision examples")
        XCTAssertEqual(userContent[0]["text"] as? String, "Describe this image.")

        XCTAssertEqual(userContent[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(userContent[1]["image_url"] as? [String: Any])
        let dataURI = try XCTUnwrap(imageURL["url"] as? String)
        XCTAssertEqual(dataURI, "data:image/png;base64,\(imageData.base64EncodedString())",
            "Data URI must round-trip MIME and base64 verbatim")
    }

    // MARK: - 2. Multiple images on one turn

    func test_multipleImages_allEncoded_inOrder() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        let img1 = fixtureImage(0x01)
        let img2 = fixtureImage(0x02)
        let img3 = fixtureImage(0x03)
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text("Compare these."),
                .image(data: img1, mimeType: "image/png"),
                .image(data: img2, mimeType: "image/jpeg"),
                .image(data: img3, mimeType: "image/webp"),
            ]),
        ])

        let stream = try backend.generate(prompt: "Compare these.", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userContent = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(userContent.count, 4, "One text part plus three image_url parts")

        XCTAssertEqual(userContent[0]["type"] as? String, "text")
        for i in 1...3 {
            XCTAssertEqual(userContent[i]["type"] as? String, "image_url",
                "Position \(i) must be an image_url part")
        }

        // Image data ordering must match the parts ordering — sabotage check:
        // if the encoder reordered images, these byte-level matches would fail.
        let url1 = try XCTUnwrap((userContent[1]["image_url"] as? [String: Any])?["url"] as? String)
        let url2 = try XCTUnwrap((userContent[2]["image_url"] as? [String: Any])?["url"] as? String)
        let url3 = try XCTUnwrap((userContent[3]["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertEqual(url1, "data:image/png;base64,\(img1.base64EncodedString())")
        XCTAssertEqual(url2, "data:image/jpeg;base64,\(img2.base64EncodedString())")
        XCTAssertEqual(url3, "data:image/webp;base64,\(img3.base64EncodedString())")
    }

    // MARK: - 3. Text/image/text ordering is preserved as a single text part

    func test_textImageTextOrdering_collapsedTextFirst() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        let imageData = fixtureImage(0xBB)
        // Two text parts + image — `textContent` joins all `.text` parts in
        // order, so the resulting content[] gets one combined text part
        // followed by the image part.
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text("Before. "),
                .image(data: imageData, mimeType: "image/png"),
                .text("After."),
            ]),
        ])

        let stream = try backend.generate(prompt: "ignored", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userContent = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(userContent.count, 2, "Two text parts collapse into one combined text + one image")
        XCTAssertEqual(userContent[0]["type"] as? String, "text")
        XCTAssertEqual(userContent[0]["text"] as? String, "Before. After.",
            "Text fragments around the image join via StructuredMessage.textContent")
        XCTAssertEqual(userContent[1]["type"] as? String, "image_url")
    }

    // MARK: - 4. Multi-turn: text-only collapse + multimodal array

    func test_multiTurn_textOnlyTurnsCollapse_multimodalTurnArrays() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        let imageData = fixtureImage(0xCC)
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text("What is this?"),
                .image(data: imageData, mimeType: "image/png"),
            ]),
            StructuredMessage(role: "assistant", content: "It looks like a logo."),
            StructuredMessage(role: "user", content: "Thanks."),
        ])

        let stream = try backend.generate(prompt: "Thanks.", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)

        // First turn: image-bearing → structured array.
        XCTAssertNotNil(messages[0]["content"] as? [[String: Any]],
            "Image-bearing user turn must serialise as a content[] array")

        // Second turn: assistant text-only → plain string content. Keeping
        // the simple form on assistant turns matches every existing
        // OpenAI-compatible compat server's expectations.
        XCTAssertEqual(messages[1]["content"] as? String, "It looks like a logo.",
            "Assistant text-only turns must collapse to plain string content")

        // Third turn: user text-only → plain string content. The wire shape
        // must not promote text-only turns to structured arrays just
        // because *some other turn* in the request carried an image.
        XCTAssertEqual(messages[2]["content"] as? String, "Thanks.",
            "Image-less user turns must keep the simple string content shape")
    }

    // MARK: - 5. Non-vision model rejects image input

    func test_nonVisionModel_rejectsImageInput() async throws {
        // `gpt-3.5-turbo` predates vision support — image attachments must
        // never be forwarded to it.
        let (backend, url) = try await makeBackend(modelName: "gpt-3.5-turbo")
        defer { MockURLProtocol.unstub(url: url) }

        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text("hi"),
                .image(data: fixtureImage(0xDD), mimeType: "image/png"),
            ]),
        ])

        do {
            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
            for try await _ in stream.events { }
            XCTFail("Should have thrown for non-vision model")
        } catch let error as InferenceError {
            guard case .inferenceFailure(let message) = error else {
                XCTFail("Expected inferenceFailure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("gpt-3.5-turbo"), "Error should name the model: \(message)")
            XCTAssertTrue(message.lowercased().contains("image"), "Error should mention images: \(message)")
        }
    }

    // MARK: - 6. Capabilities flip with model name

    func test_capabilities_supportsVision_reflectsModelName() {
        let backend = OpenAIBackend()

        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "x",
            modelName: "gpt-4o-mini"
        )
        XCTAssertTrue(backend.capabilities.supportsVision,
            "gpt-4o-mini must advertise vision support")

        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "x",
            modelName: "gpt-4o-2024-08-06"
        )
        XCTAssertTrue(backend.capabilities.supportsVision,
            "Dated gpt-4o variants must advertise vision support")

        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "x",
            modelName: "gpt-3.5-turbo"
        )
        XCTAssertFalse(backend.capabilities.supportsVision,
            "gpt-3.5-turbo predates vision support — must not advertise it")

        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "x",
            modelName: "o1-mini"
        )
        XCTAssertTrue(backend.capabilities.supportsVision,
            "o1 reasoning family must advertise vision support")
    }

    // Direct classifier coverage moved to BackendVisionCapabilityTests
    // (test_openAIChatCompletionsVisionGate_allowsOnlyImplementedVisionFamilies)
    // when the helper was lifted out of OpenAIBackend into BackendVisionCapability.

    // MARK: - 8. Structured-text-only doesn't promote to array

    func test_structuredTextOnly_keepsSimpleStringContent() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        // Coordinator typically sets BOTH structured + flattened histories.
        // When the structured form has zero images, the encoder must stay on
        // the flattened (legacy) path so existing OpenAI-compat servers see
        // the same wire shape they did before this change.
        backend.setStructuredHistory([
            StructuredMessage(role: "user", content: "hello"),
            StructuredMessage(role: "assistant", content: "hi"),
        ])
        backend.setConversationHistory([
            (role: "user", content: "hello"),
            (role: "assistant", content: "hi"),
        ])

        let stream = try backend.generate(prompt: "next", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["content"] as? String, "hello",
            "Text-only structured turns must NOT promote to a content[] array")
        XCTAssertEqual(messages[1]["content"] as? String, "hi")
    }

    // MARK: - 9. StructuredHistoryReceiver conformance

    func test_conformsToStructuredHistoryReceiver() {
        // A protocol-typed binding fails to compile if the conformance is
        // ever removed — the runtime cast is downcast through `Any` so the
        // compiler doesn't warn that the test is tautological while still
        // failing the build if the conformance regresses.
        let backend: Any = OpenAIBackend()
        XCTAssertNotNil(backend as? StructuredHistoryReceiver,
            "OpenAIBackend must conform to StructuredHistoryReceiver so GenerationQueue routes MessagePart.image parts to it")
    }

    // MARK: - 10. Data URI shape — exact MIME + base64 round-trip

    func test_dataURI_exactShape() {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let uri = CloudImageEncoding.dataURI(data: bytes, mimeType: "image/jpeg")
        XCTAssertEqual(uri, "data:image/jpeg;base64,3q2+7w==",
            "dataURI must produce the exact RFC 2397 form OpenAI expects")
    }

    // MARK: - 11. MIME passthrough — exotic types still surface verbatim

    func test_mimeType_passthroughVerbatim() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        // Pass an unusual MIME — the backend should not silently rewrite
        // it. If OpenAI rejects the request the upstream 400 surfaces; we
        // don't mask that by guessing a default.
        let bytes = fixtureImage(0xEE)
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text("look"),
                .image(data: bytes, mimeType: "image/heic"),
            ]),
        ])

        let stream = try backend.generate(prompt: "look", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userContent = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        let imagePart = try XCTUnwrap(userContent.first(where: { $0["type"] as? String == "image_url" }))
        let imageURL = try XCTUnwrap(imagePart["image_url"] as? [String: Any])
        let dataURI = try XCTUnwrap(imageURL["url"] as? String)
        XCTAssertTrue(dataURI.hasPrefix("data:image/heic;base64,"),
            "MIME must pass through verbatim — got \(dataURI.prefix(40))")
    }
}
#endif
