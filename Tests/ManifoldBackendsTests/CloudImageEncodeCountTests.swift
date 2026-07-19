import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldFoundation
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore

/// Grounds audit claim #4 ("raw image bytes live in `MessagePart.image`,
/// re-encoded every turn") with a measurement.
///
/// `CloudImageEncoding.base64String(from:)` is the single seam through which
/// every cloud backend turns a `MessagePart.image` into its wire payload.
/// There is no caching layer on top — each turn that re-sends the same
/// attachment in `structuredHistory` re-runs the encoder. These tests pin
/// that contract so the eventual blob-store / cache PR can flip the
/// assertion atomically.
///
/// The encoder is observed via a per-test hook
/// (``CloudImageEncoding/setEncodeHook(_:)``) installed in `setUp` and torn down in
/// `tearDown`. The hook fires exactly once per `base64String` call, so
/// counting hook invocations equals counting encode calls — without having
/// to instrument every backend's request-builder by hand.
final class CloudImageEncodeCountTests: XCTestCase {

    // MARK: - Hook plumbing

    /// `nonisolated(unsafe)` matches the encoder hook's storage shape; this
    /// counter is mutated only from the encoder's call site (synchronous
    /// inside the request-build path) and read from the test thread after
    /// stream consumption completes.
    private final class EncodeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }

        func increment() {
            lock.lock()
            _value += 1
            lock.unlock()
        }
    }

    private var counter: EncodeCounter!

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        counter = EncodeCounter()
        let counter = counter!
        CloudImageEncoding.setEncodeHook { counter.increment() }
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        // Reset before nilling out the local ref so a leftover hook from a
        // prior failure cannot leak into the next test in the same process.
        CloudImageEncoding.setEncodeHook(nil)
        counter = nil
        super.tearDown()
    }

    // MARK: - Backend setup

    private func makeBackend(
        modelName: String = "claude-sonnet-4-20250514"
    ) async throws -> (ClaudeBackend, URL) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = ClaudeBackend(urlSession: session)
        // UUID-scoped host keeps stubs isolated across the parallel test
        // runner — see `feedback_mockurlprotocol.md` in user memory.
        let url = URL(string: "https://claude-encode-count-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-ant-test", modelName: modelName)
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        return (backend, url)
    }

    private func sseStub(url: URL) {
        let chunk = Data("""
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}\n\ndata: {"type":"message_stop"}\n\n
            """.utf8)
        MockURLProtocol.stub(url: url, response: .sse(chunks: [chunk], statusCode: 200))
    }

    /// 4-byte payload — see ClaudeImageInputTests for the rationale; the
    /// encoder doesn't decode the data, only base64-encodes it.
    private func fixtureImage(_ marker: UInt8) -> Data {
        Data([0x89, 0x50, 0x4E, marker])
    }

    // MARK: - Tests

    /// Three consecutive `generate(...)` calls on the same backend, each
    /// with the same single-image user turn surfaced in
    /// ``ClaudeBackend/setStructuredHistory(_:)``, must produce three
    /// encode invocations. There is no caching today — this test is the
    /// regression guard for that fact, and the bar the eventual blob-store
    /// PR must move.
    func test_repeatedTurnsReencodeImagesEachTime() async throws {
        let (backend, url) = try await makeBackend()
        defer { MockURLProtocol.unstub(url: url) }
        sseStub(url: url)

        let imageData = fixtureImage(0x42)
        let history = [
            StructuredMessage(role: "user", parts: [
                .image(data: imageData, mimeType: "image/png"),
                .text("Describe this."),
            ]),
        ]

        for _ in 0..<3 {
            let stream = try backend.generate(
                prompt: "Describe this.",
                systemPrompt: nil,
                config: GenerationConfig(),
                hints: GenerationRuntimeHints(history: history)
            )
            for try await _ in stream.events { }
        }

        XCTAssertEqual(
            counter.value, 3,
            "Three turns with one image each must produce three encode calls — no per-attachment cache exists at this seam."
        )
    }

    /// Three turns each carrying two attachments must produce six encode
    /// calls. Confirms the count scales linearly with attachment count.
    func test_encodeCountMatchesAttachmentCount() async throws {
        let (backend, url) = try await makeBackend()
        defer { MockURLProtocol.unstub(url: url) }
        sseStub(url: url)

        let img1 = fixtureImage(0x01)
        let img2 = fixtureImage(0x02)
        let history = [
            StructuredMessage(role: "user", parts: [
                .image(data: img1, mimeType: "image/png"),
                .image(data: img2, mimeType: "image/jpeg"),
                .text("Compare these."),
            ]),
        ]

        for _ in 0..<3 {
            let stream = try backend.generate(
                prompt: "Compare these.",
                systemPrompt: nil,
                config: GenerationConfig(),
                hints: GenerationRuntimeHints(history: history)
            )
            for try await _ in stream.events { }
        }

        XCTAssertEqual(
            counter.value, 6,
            "Three turns × two attachments must produce six encode calls — every attachment is re-encoded on every turn."
        )
    }
}
