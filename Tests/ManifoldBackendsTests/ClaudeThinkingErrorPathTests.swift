import XCTest
import Foundation
@testable import ManifoldFoundation
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Pins the `ThinkingBlockManager.flushIfOpen` parser-error path for Claude:
/// when an upstream `error` event interrupts an open thinking block, the
/// stream must yield `.thinkingCompleted` before the throw so consumers don't
/// hang in a thinking-only state.
///
/// This file uses XCTest (not Swift Testing) on purpose — see
/// `ManifoldCoreTests/SwiftTestingAuditTest.swift` (issue #681). New
/// `@Suite/@Test` annotations in `ManifoldBackendsTests/CloudThinkingTokenTests.swift`
/// are gated by an allowlist; rather than raise that allowlist for one
/// regression test, we keep this XCTest-resident.
final class ClaudeThinkingErrorPathTests: XCTestCase {

    private var session: URLSession!
    private var mockURL: URL!

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        mockURL = URL(string: "https://claude-error-path-\(UUID().uuidString).test")!
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        if let url = mockURL {
            MockURLProtocol.unstub(url: url.appendingPathComponent("v1/messages"))
        }
        session = nil
        mockURL = nil
        super.tearDown()
    }

    private func sseData(_ json: String) -> Data {
        Data("data: \(json)\n\n".utf8)
    }

    func test_errorMidThinkingBlock_emitsThinkingCompleteBeforeThrow() async throws {
        let backend = ClaudeBackend(urlSession: session)
        backend.configure(baseURL: mockURL, apiKey: "sk-test", modelName: "claude-sonnet-4-20250514")
        let url = mockURL.appendingPathComponent("v1/messages")

        let chunks: [Data] = [
            sseData(#"{"type":"message_start","message":{"usage":{"input_tokens":10}}}"#),
            sseData(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#),
            sseData(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Pondering"}}"#),
            // Anthropic SSE error event mid-thinking. ClaudeBackend's
            // `extractStreamError` parses this and the parse loop throws.
            sseData(#"{"type":"error","error":{"type":"overloaded_error","message":"Server overloaded"}}"#),
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let stream = try backend.generate(
            prompt: "x",
            systemPrompt: nil,
            config: GenerationConfig(maxThinkingTokens: 4096)
        )

        var sawThinkingToken = false
        var sawThinkingComplete = false
        var threw = false
        do {
            for try await event in stream.events {
                switch event {
                case .thinkingToken: sawThinkingToken = true
                case .thinkingCompleted: sawThinkingComplete = true
                default: break
                }
            }
        } catch {
            threw = true
        }

        XCTAssertTrue(sawThinkingToken, "expected at least one .thinkingToken before the error event")
        XCTAssertTrue(threw, "expected the upstream error event to throw out of the stream")
        XCTAssertTrue(sawThinkingComplete,
                      ".thinkingCompleted must fire before the throw so consumers don't hang in a thinking-only state")
    }
}
