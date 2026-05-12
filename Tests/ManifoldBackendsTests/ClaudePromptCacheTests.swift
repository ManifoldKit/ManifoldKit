#if CloudSaaS
import XCTest
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloud
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for ``ClaudeBackend`` prompt-cache breakpoint emission.
///
/// Covers #1205: system prompt serialised as an array content block with
/// `cache_control` when `cachePolicy == .automatic`, plain string when
/// `.disabled`, and the last tool definition tagged when tools are present.
@MainActor
final class ClaudePromptCacheTests: XCTestCase {

    private var mockURL: URL!
    private var messagesURL: URL!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        mockURL = URL(string: "https://claude-cache-\(UUID().uuidString).test")!
        messagesURL = mockURL.appendingPathComponent("v1/messages")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        if let url = messagesURL {
            MockURLProtocol.unstub(url: url)
        }
        session = nil
        mockURL = nil
        messagesURL = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeBackend(cachePolicy: PromptCachePolicy = .automatic) -> ClaudeBackend {
        let backend = ClaudeBackend(urlSession: session)
        backend.configure(baseURL: mockURL, apiKey: "sk-ant-test", modelName: "claude-sonnet-4-20250514")
        backend.cachePolicy = cachePolicy
        return backend
    }

    private func stubMessageStop() {
        let chunk = Data("data: {\"type\":\"message_stop\"}\n\n".utf8)
        MockURLProtocol.stub(url: messagesURL, response: .sse(chunks: [chunk], statusCode: 200))
    }

    /// Fires a minimal generate() and returns the captured request body as JSON.
    private func captureRequestBody(
        backend: ClaudeBackend,
        systemPrompt: String?,
        config: GenerationConfig = GenerationConfig()
    ) async throws -> [String: Any] {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        stubMessageStop()

        let stream = try backend.generate(prompt: "hi", systemPrompt: systemPrompt, config: config)
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url?.host == mockURL.host })
        let data: Data
        if let direct = captured?.httpBody {
            data = direct
        } else if let bodyStream = captured?.httpBodyStream {
            var buf = Data()
            bodyStream.open()
            let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { ptr.deallocate() }
            while bodyStream.hasBytesAvailable {
                let n = bodyStream.read(ptr, maxLength: 4096)
                if n > 0 { buf.append(ptr, count: n) }
            }
            bodyStream.close()
            data = buf
        } else {
            XCTFail("No request body captured")
            return [:]
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - System prompt as array block (automatic)

    /// With `.automatic`, `system` must be an array containing a single text
    /// block with `cache_control: {type: "ephemeral"}`.
    ///
    /// Sabotage check: change `resolvedCachePolicy == .automatic` to `false`
    /// in `ClaudeBackend.buildRequest`; the system field will be a plain String
    /// and this test fails on the `XCTAssertNotNil(blocks)` assertion.
    func test_systemPrompt_automatic_emitsArrayBlockWithCacheControl() async throws {
        let backend = makeBackend(cachePolicy: .automatic)
        let json = try await captureRequestBody(backend: backend, systemPrompt: "You are helpful.")

        let blocks = json["system"] as? [[String: Any]]
        XCTAssertNotNil(blocks, "system must be an array of content blocks when cachePolicy is .automatic")
        XCTAssertEqual(blocks?.count, 1)

        let block = try XCTUnwrap(blocks?.first)
        XCTAssertEqual(block["type"] as? String, "text")
        XCTAssertEqual(block["text"] as? String, "You are helpful.")

        let cacheControl = try XCTUnwrap(block["cache_control"] as? [String: Any])
        XCTAssertEqual(cacheControl["type"] as? String, "ephemeral")
    }

    // MARK: - System prompt as plain string (disabled)

    /// With `.disabled`, `system` must remain a plain String — no content
    /// blocks, no `cache_control` — preserving pre-0.25.0 wire behaviour.
    ///
    /// Sabotage check: set `cachePolicy = .automatic` in the test; the
    /// assertion on `json["system"] as? String` will return nil and fail.
    func test_systemPrompt_disabled_emitsPlainString() async throws {
        let backend = makeBackend(cachePolicy: .disabled)
        let json = try await captureRequestBody(backend: backend, systemPrompt: "You are helpful.")

        let systemString = json["system"] as? String
        XCTAssertEqual(systemString, "You are helpful.",
                       "system must be a plain String when cachePolicy is .disabled")
        XCTAssertNil(json["system"] as? [[String: Any]],
                     "system must NOT be a block array when cachePolicy is .disabled")
    }

    // MARK: - Empty system prompt omitted

    /// A nil or empty system prompt must not emit a `system` field regardless
    /// of cache policy — the Anthropic API treats an absent system as "no
    /// system prompt" and both nil and empty are equivalent to the caller.
    func test_systemPrompt_nil_omitsSystemField() async throws {
        let backend = makeBackend(cachePolicy: .automatic)
        let json = try await captureRequestBody(backend: backend, systemPrompt: nil)
        XCTAssertNil(json["system"], "system field must be absent when systemPrompt is nil")
    }

    func test_systemPrompt_empty_omitsSystemField() async throws {
        let backend = makeBackend(cachePolicy: .automatic)
        let json = try await captureRequestBody(backend: backend, systemPrompt: "")
        XCTAssertNil(json["system"], "system field must be absent when systemPrompt is empty")
    }

    // MARK: - Tool catalog last-entry tagging (automatic)

    /// With `.automatic` and a non-empty tool list, the last entry in the
    /// `tools[]` array must carry `cache_control: {type: "ephemeral"}`.
    /// Earlier entries must not be tagged — Anthropic caches everything up to
    /// and including the last tagged block, so tagging every entry would create
    /// redundant breakpoints.
    ///
    /// Sabotage check: remove the `toolEntries[toolEntries.count - 1]["cache_control"]`
    /// assignment in `ClaudeBackend.buildRequest`; the last tool will lack
    /// `cache_control` and the assertion fails.
    func test_tools_automatic_tagsLastToolWithCacheControl() async throws {
        let backend = makeBackend(cachePolicy: .automatic)

        var cfg = GenerationConfig()
        cfg.tools = [
            ToolDefinition(name: "search", description: "Web search", parameters: .object([:])),
            ToolDefinition(name: "calculator", description: "Do math", parameters: .object([:])),
        ]
        cfg.toolChoice = .auto

        let json = try await captureRequestBody(backend: backend, systemPrompt: nil, config: cfg)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 2)

        // First tool must NOT have cache_control.
        XCTAssertNil(tools[0]["cache_control"],
                     "Only the last tool should be tagged; first tool must have no cache_control")

        // Last tool must have cache_control: {type: "ephemeral"}.
        let lastCC = try XCTUnwrap(tools[1]["cache_control"] as? [String: Any])
        XCTAssertEqual(lastCC["type"] as? String, "ephemeral")
    }

    // MARK: - Tool catalog with disabled policy

    /// With `.disabled`, no tool entry should carry `cache_control`.
    func test_tools_disabled_noToolTagged() async throws {
        let backend = makeBackend(cachePolicy: .disabled)

        var cfg = GenerationConfig()
        cfg.tools = [
            ToolDefinition(name: "search", description: "Web search", parameters: .object([:])),
        ]
        cfg.toolChoice = .auto

        let json = try await captureRequestBody(backend: backend, systemPrompt: nil, config: cfg)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        for (i, tool) in tools.enumerated() {
            XCTAssertNil(tool["cache_control"],
                         "Tool at index \(i) must not have cache_control when cachePolicy is .disabled")
        }
    }

    // MARK: - Single-tool list tagging

    /// Edge case: a single tool must be tagged when policy is automatic.
    func test_tools_automatic_singleTool_isTagged() async throws {
        let backend = makeBackend(cachePolicy: .automatic)

        var cfg = GenerationConfig()
        cfg.tools = [
            ToolDefinition(name: "ping", description: "Ping", parameters: .object([:])),
        ]
        cfg.toolChoice = .auto

        let json = try await captureRequestBody(backend: backend, systemPrompt: nil, config: cfg)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let cc = try XCTUnwrap(tools[0]["cache_control"] as? [String: Any])
        XCTAssertEqual(cc["type"] as? String, "ephemeral")
    }

    // MARK: - Default policy is .automatic

    /// Verify ClaudeBackend ships with .automatic as the default so all users
    /// get the cost reduction without opting in.
    func test_defaultCachePolicy_isAutomatic() {
        let backend = ClaudeBackend(urlSession: session)
        if case .automatic = backend.cachePolicy {
            // Expected
        } else {
            XCTFail("Default cachePolicy must be .automatic, got \(backend.cachePolicy)")
        }
    }
}

// MARK: - ClaudePayloadParser cache usage parsing tests

final class ClaudePayloadParserCacheUsageTests: XCTestCase {

    func test_parseCacheUsage_messageStart_withBothFields_returnsCacheUsage() {
        let payload = """
        {"type":"message_start","message":{"usage":{"input_tokens":25,"cache_creation_input_tokens":2200,"cache_read_input_tokens":0}}}
        """
        // cache_read = 0 with creation > 0 → should still return a CacheUsage
        // (creation is the signal that caching is active)
        let usage = ClaudePayloadParser.parseCacheUsage(from: payload)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.cacheCreationInputTokens, 2200)
        XCTAssertEqual(usage?.cacheReadInputTokens, 0)
    }

    func test_parseCacheUsage_messageStart_readHit_returnsCacheUsage() {
        let payload = """
        {"type":"message_start","message":{"usage":{"input_tokens":25,"cache_creation_input_tokens":0,"cache_read_input_tokens":2200}}}
        """
        let usage = ClaudePayloadParser.parseCacheUsage(from: payload)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.cacheCreationInputTokens, 0)
        XCTAssertEqual(usage?.cacheReadInputTokens, 2200)
    }

    func test_parseCacheUsage_messageStart_noCacheFields_returnsNil() {
        // No cache activity → parser must return nil (avoids logging on uncached turns)
        let payload = """
        {"type":"message_start","message":{"usage":{"input_tokens":25,"output_tokens":0}}}
        """
        XCTAssertNil(ClaudePayloadParser.parseCacheUsage(from: payload))
    }

    func test_parseCacheUsage_messageDelta_returnsNil() {
        // Cache counts only live on message_start, not message_delta.
        let payload = """
        {"type":"message_delta","usage":{"output_tokens":42}}
        """
        XCTAssertNil(ClaudePayloadParser.parseCacheUsage(from: payload))
    }

    func test_parseCacheUsage_malformed_returnsNil() {
        XCTAssertNil(ClaudePayloadParser.parseCacheUsage(from: "not json"))
        XCTAssertNil(ClaudePayloadParser.parseCacheUsage(from: "{}"))
    }

    func test_parseCacheUsage_bothFieldsZero_returnsNil() {
        // Zero creation + zero read = no caching occurred — return nil so
        // we don't emit a pointless log line on every uncached turn.
        let payload = """
        {"type":"message_start","message":{"usage":{"input_tokens":25,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        XCTAssertNil(ClaudePayloadParser.parseCacheUsage(from: payload))
    }
}
#endif
