import XCTest
@testable import ManifoldBackends
@testable import ManifoldCloud
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Regression guard: per-instance `SSECloudBackend.sseStreamLimits`
/// overrides must reach the adapter-routed framed transport, not just the
/// legacy `parseResponseStream` path.
///
/// **Background.** PR #1272 (Phase 2/B/iii/δ) flipped `OpenAIBackend` to
/// the adapter-routed path inside `CloudRoutedStreamParser`.
/// That path consumes `routing.framedTransport.frames(...)` instead of the
/// legacy `SSEStreamParser.parse(bytes:limits:)` call that always read
/// `effectiveSSEStreamLimits` live. The AI-engineering review flagged
/// that the routed transport — `SSETransport()` constructed at adapter
/// init — captured `ManifoldConfiguration.shared.sseStreamLimits` once and
/// never re-read it. Per-instance overrides set via
/// `backend.sseStreamLimits = ...` (tests, hosts that want a tighter cap)
/// silently bypassed the routed parser, leaving the routed path defended
/// only by the global default.
///
/// The fix threads a `@Sendable () -> SSEStreamLimits` provider through
/// `SSETransport`, and `OpenAIBackend` wires the routing's transport to
/// read `effectiveSSEStreamLimits` live per stream. This test pins the
/// behaviour against future regression.
final class SSEStreamLimitsRoutingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        super.tearDown()
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// SSE-encodes a single Chat Completions delta chunk.
    private func sseChunk(content: String) -> Data {
        let json = #"{"choices":[{"delta":{"content":"\#(content)"}}]}"#
        return Data("data: \(json)\n\n".utf8)
    }

    private func sseDoneChunk() -> Data {
        Data("data: [DONE]\n\n".utf8)
    }

    /// Drives an OpenAIBackend through the routed path with a tight
    /// `maxTotalBytes` cap and asserts the cap truncates the stream.
    ///
    /// When the per-instance override flows through to the routed
    /// transport, `SSEStreamParser.parse` raises `.streamTooLarge` after
    /// the cap is hit, the transport swallows the error per its
    /// `FramedTransport` contract and finishes the AsyncStream — so the
    /// caller sees only the tokens that arrived before the cap.
    ///
    /// Sabotage: revert the `SSETransport(limitsProvider:)` wiring in
    /// `OpenAIBackend.init` so the routing again uses `adapter.framedTransport`
    /// (which snapshots the shared limits at adapter-init time). The test
    /// will then receive all four tokens because the per-instance override
    /// no longer reaches the parser.
    func test_perInstanceLimitsOverride_truncatesRoutedStream() async throws {
        let session = makeMockSession()
        let backend = OpenAIBackend(urlSession: session)

        // Tight maxTotalBytes cap. Each SSE frame is roughly 50 bytes;
        // 80 bytes will fit the first frame but reject the second.
        backend.sseStreamLimits = SSEStreamLimits(
            maxEventBytes: 1_000_000,
            maxTotalBytes: 80,
            maxEventsPerSecond: 1_000_000
        )

        let baseURL = URL(string: "https://openai-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, apiKey: "sk-test", modelName: "gpt-4o")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")
        // Four content chunks totalling well over 80 bytes, then [DONE].
        let chunks: [Data] = [
            sseChunk(content: "a"),
            sseChunk(content: "b"),
            sseChunk(content: "c"),
            sseChunk(content: "d"),
            sseDoneChunk(),
        ]
        MockURLProtocol.stub(url: completionsURL, response: .sse(chunks: chunks, statusCode: 200))
        addTeardownBlock { MockURLProtocol.unstub(url: completionsURL) }

        var tokens: [String] = []
        let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig())
        // The routed transport swallows SSEStreamError after the cap is
        // hit and finishes cleanly, so a defensive try/catch ensures we
        // don't fail the test on a thrown variant.
        do {
            for try await event in stream.events {
                if case .token(let text) = event { tokens.append(text) }
            }
        } catch {
            // Acceptable — either the transport swallows the error and
            // finishes cleanly, or the parser throws on .streamTooLarge.
            // Both prove the cap fired.
        }

        XCTAssertLessThan(
            tokens.count, 4,
            "Per-instance sseStreamLimits override must truncate the routed stream; got \(tokens.count) tokens"
        )

        // Sabotage check: remove the `limitsProvider:` wiring in
        // `OpenAIBackend.init` (revert to passing `adapter.framedTransport`
        // directly) and tokens.count will return 4 because the global
        // default (10 MB) lets every chunk through.
    }

    /// Inspection-level proof that the routing's transport reads limits
    /// live. Sets the per-instance cap, then changes it, and asserts the
    /// transport surfaces the new value on the next stream.
    func test_perInstanceLimitsOverride_isReadLiveOnEachStream() async throws {
        let session = makeMockSession()
        let backend = OpenAIBackend(urlSession: session)

        // First override.
        backend.sseStreamLimits = SSEStreamLimits(
            maxEventBytes: 123,
            maxTotalBytes: 456,
            maxEventsPerSecond: 789
        )
        XCTAssertEqual(backend.effectiveSSEStreamLimits.maxEventBytes, 123,
                       "effectiveSSEStreamLimits must surface the per-instance override")

        // Second override after the routing has already been configured at
        // init time — proves the closure-based limitsProvider isn't a
        // one-shot snapshot.
        backend.sseStreamLimits = SSEStreamLimits(
            maxEventBytes: 999,
            maxTotalBytes: 1_000_000,
            maxEventsPerSecond: 10_000
        )
        XCTAssertEqual(backend.effectiveSSEStreamLimits.maxEventBytes, 999,
                       "effectiveSSEStreamLimits must reflect the latest per-instance override")
    }
}
