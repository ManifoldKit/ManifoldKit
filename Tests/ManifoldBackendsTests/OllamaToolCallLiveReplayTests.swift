import XCTest
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloud
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Replays the live-captured Ollama SSE corpus at
/// `Tests/Fixtures/ollama/tool-calls/<version>/` through ``OllamaBackend``
/// and asserts the emitted `[GenerationEvent]` sequence matches each
/// scenario's `<name>.expected.jsonl` sibling.
///
/// Each `.sse` fixture is a **complete** NDJSON stream (including the
/// terminal `done:true` chunk) — these are shipped as-if captured from a
/// live Ollama server so the test pins the full wire-format contract.
///
/// Skipped until Agent D's tool-call parser lands in main — see
/// ``OllamaAdversarialJSONTests`` for the coordination notes.
final class OllamaToolCallLiveReplayTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        super.tearDown()
    }

    private var ollamaToolCallingIsWired: Bool {
        OllamaBackend().capabilities.supportsToolCalling
    }

    /// Locates the versioned capture directory. Picks the single
    /// sub-directory that isn't `adversarial/` — tests should only ever
    /// have one version pinned at a time so the CI job's `OLLAMA_VERSION`
    /// env var has an obvious mapping.
    private func captureDirectory() -> URL? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("ollama")
            .appendingPathComponent("tool-calls")
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        return entries.first { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            return url.lastPathComponent != "adversarial"
        }
    }

    // MARK: - Expected event shape

    private struct ExpectedEvent: Decodable {
        var event: String
        var text: String?
        var tool_name: String?
        var arguments_contains: String?
        var prompt: Int?
        var completion: Int?
    }

    // MARK: - Harness

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeConfiguredBackend() -> (OllamaBackend, URL) {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-live-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.1:8b")
        return (backend, baseURL.appendingPathComponent("api/chat"))
    }

    /// Runs a raw NDJSON capture through the backend and returns events.
    private func replay(captureData: Data) async throws -> [GenerationEvent] {
        let (backend, chatURL) = makeConfiguredBackend()
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        // Split on newline boundaries so MockURLProtocol delivers chunks
        // that mirror the NDJSON line framing Ollama uses on the wire.
        let lines = captureData
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { Data($0) + Data([UInt8(ascii: "\n")]) }
            .filter { $0.count > 1 } // skip trailing empty from final newline

        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: lines, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "replay", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    /// Finds all `<name>.sse` fixtures in the pinned-version directory.
    private func liveFixtures() -> [URL] {
        guard let dir = captureDirectory() else { return [] }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "sse" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    private func loadExpected(for sseURL: URL) throws -> [ExpectedEvent] {
        let base = sseURL.deletingPathExtension().lastPathComponent
        let expectedURL = sseURL.deletingLastPathComponent().appendingPathComponent("\(base).expected.jsonl")
        let contents = try String(contentsOf: expectedURL, encoding: .utf8)
        let lines = contents.split(whereSeparator: \.isNewline)
        let decoder = JSONDecoder()
        return try lines.map { line in
            try decoder.decode(ExpectedEvent.self, from: Data(line.utf8))
        }
    }

    // MARK: - Tests

    func test_liveFixtures_presentAndLabeled() {
        let fixtures = liveFixtures()
        XCTAssertGreaterThanOrEqual(fixtures.count, 3, "expected at least 3 live capture scenarios")

        let names = Set(fixtures.map { $0.deletingPathExtension().lastPathComponent })
        XCTAssertTrue(names.contains("simple-tool-call"))
        XCTAssertTrue(names.contains("two-calls-one-message"))
        XCTAssertTrue(names.contains("inline-answer-no-tool"))
    }

    /// Fixture `inline-answer-no-tool.sse` exercises the content-only path
    /// that is already wired today. This specific scenario runs
    /// independently of Agent D's work.
    func test_inlineAnswer_noTool_producesTokensAndUsage() async throws {
        guard let dir = captureDirectory() else {
            XCTFail("no pinned Ollama version directory found")
            return
        }
        let sse = try Data(contentsOf: dir.appendingPathComponent("inline-answer-no-tool.sse"))
        let events = try await replay(captureData: sse)

        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        XCTAssertEqual(tokens, ["The", " capital", " of France", " is Paris."])

        let usage = events.compactMap { event -> (Int, Int)? in
            if case .usage(let u) = event { return (u.promptTokens, u.completionTokens) } else { return nil }
        }
        XCTAssertEqual(usage.count, 1, "expected exactly one .usage event from the done-line")
        XCTAssertEqual(usage.first?.0, 30)
        XCTAssertEqual(usage.first?.1, 7)
    }

    /// Full corpus walker — gated on Agent D's parser landing.
    func test_allLiveFixtures_matchExpectedJSONL() async throws {
        try XCTSkipUnless(
            ollamaToolCallingIsWired,
            "Tool-call-bearing fixtures require Agent D's parser. Un-skips after merge."
        )

        for sseURL in liveFixtures() {
            let base = sseURL.deletingPathExtension().lastPathComponent
            let sseData = try Data(contentsOf: sseURL)
            let expected = try loadExpected(for: sseURL)
            let events = try await replay(captureData: sseData)

            // Build a slim comparable projection of the actual event stream.
            var projected: [ExpectedEvent] = []
            for e in events {
                switch e {
                case .token(let t):
                    projected.append(ExpectedEvent(event: "token", text: t, tool_name: nil, arguments_contains: nil, prompt: nil, completion: nil))
                case .toolCall(let call):
                    projected.append(ExpectedEvent(event: "toolCall", text: nil, tool_name: call.toolName, arguments_contains: nil, prompt: nil, completion: nil))
                case .usage(let u):
                    projected.append(ExpectedEvent(event: "usage", text: nil, tool_name: nil, arguments_contains: nil, prompt: u.promptTokens, completion: u.completionTokens))
                case .thinkingToken, .thinkingCompleted, .thinkingSignature:
                    // Not exercised by tool-call fixtures; ignore for
                    // forward-compat with future thinking-in-tool-call
                    // captures.
                    break
                case .toolResult, .toolIterationLimitExceeded:
                    // Raw backend replay never emits orchestrator-level
                    // events. Exhaustive stub so the switch stays honest as
                    // GenerationEvent grows.
                    break
                case .kvCacheReuse:
                    break
                case .throttleDiagnostic:
                    // Cooperative thermal pause — informational only;
                    // raw backend replay neither emits nor projects it.
                    break
                case .toolCallStart, .toolCallArgumentsDelta:
                    // Streaming tool-call deltas are projected only by
                    // backends that opt into `streamsToolCallArguments`;
                    // the live Ollama replay parses whole calls.
                    break
                case .toolProgress, .toolDispatchStarted, .toolDispatchCompleted, .toolCallApproved:
                    // Orchestrator-level dispatch lifecycle events; raw
                    // backend replay never emits them.
                    break
                case .prefillProgress:
                    break
                case .handoffRequested:
                    // Runtime-synthesised handoff event; live raw backend
                    // replays never emit this case.
                    break
                }
            }

            XCTAssertEqual(
                projected.count,
                expected.count,
                "\(base): expected \(expected.count) events, got \(projected.count): \(events)"
            )

            for (actual, want) in zip(projected, expected) {
                XCTAssertEqual(actual.event, want.event, "\(base): event kind mismatch")
                if let wantText = want.text {
                    XCTAssertEqual(actual.text, wantText, "\(base): token text mismatch")
                }
                if let wantTool = want.tool_name {
                    XCTAssertEqual(actual.tool_name, wantTool, "\(base): tool_name mismatch")
                }
                if let wantPrompt = want.prompt {
                    XCTAssertEqual(actual.prompt, wantPrompt, "\(base): prompt usage mismatch")
                }
                if let wantCompletion = want.completion {
                    XCTAssertEqual(actual.completion, wantCompletion, "\(base): completion usage mismatch")
                }
            }

            // Check arguments_contains against the real ToolCall payload
            // because the projection above doesn't carry raw arguments.
            let actualToolCalls = events.compactMap { event -> ToolCall? in
                if case .toolCall(let c) = event { return c } else { return nil }
            }
            let expectedToolCallsWithArgs = expected
                .filter { $0.event == "toolCall" && $0.arguments_contains != nil }
            for (idx, want) in expectedToolCallsWithArgs.enumerated() {
                guard idx < actualToolCalls.count else {
                    XCTFail("\(base): expected tool call #\(idx) missing")
                    continue
                }
                if let needle = want.arguments_contains {
                    XCTAssertTrue(
                        actualToolCalls[idx].arguments.contains(needle),
                        "\(base): tool call #\(idx) arguments '\(actualToolCalls[idx].arguments)' does not contain '\(needle)'"
                    )
                }
            }
        }
    }
}
