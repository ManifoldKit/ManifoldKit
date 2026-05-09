#if Ollama
import XCTest
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloud
@testable import ManifoldInference
import ManifoldTestSupport

/// Replays the adversarial JSON fixture corpus at
/// `Tests/Fixtures/ollama/tool-calls/adversarial/` through
/// ``OllamaBackend``'s streaming path and asserts each fixture's
/// `expected.json` outcome.
///
/// ## Why a fixture corpus?
///
/// Ollama's tool-call wire format is **not** pinned by a spec — different
/// minor versions have emitted `arguments` as either a string or an object,
/// `id` as either present or synthesised client-side, and the OpenAI-compat
/// endpoint uses the `function.name/arguments` wrapper while the native
/// `/api/chat` sometimes uses flat `name/arguments`. Each of these variants
/// has been observed in the wild. Encoding every shape as a hand-written
/// `@Test` would be brittle; a fixture corpus makes the drift *observable*
/// in Git — new shapes get added as files, not code churn.
///
/// ## Coordination with Agent D's parser
///
/// As of this PR's creation, Agent D is wiring the tool-call emission path
/// in ``OllamaBackend/parseResponseStream(bytes:config:continuation:)`` in
/// parallel. Tests are gated by
/// ``ollamaToolCallingIsWired`` so they run as XCTSkip until Agent D's PR
/// merges and the capability flag flips to `true`. After rebase, the skip
/// evaporates and the corpus runs against the real parser.
///
/// The gating choice is deliberately lightweight: a single probe
/// (`OllamaBackend().capabilities.supportsToolCalling`) rather than an
/// `#if` condition, so the PR-merge sequence is "D lands → capability
/// flips → these tests go green" without a follow-up patch.
final class OllamaAdversarialJSONTests: XCTestCase {

    /// Probe for whether tool-call emission is wired yet.
    ///
    /// When Agent D's PR merges this flips to `true` and all tests in this
    /// file become active. Until then they XCTSkip with a note pointing to
    /// the coordination context.
    private var ollamaToolCallingIsWired: Bool {
        OllamaBackend().capabilities.supportsToolCalling
    }

    /// Shape of `<name>.expected.json` sibling files.
    private struct Expected: Decodable {
        var should_emit: Bool
        var event_type: String?
        var tool_name: String?
        var arguments_contains: String?
        var should_log_warning: Bool
        var expected_call_count: Int?
        var notes: String?
    }

    // MARK: - Harness

    /// Locates the adversarial corpus directory relative to this source file.
    /// Mirrors the `#filePath` pattern used by `JSONSchemaValidatorTests`.
    private func corpusDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()       // Tests/ManifoldBackendsTests
            .deletingLastPathComponent()       // Tests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("ollama")
            .appendingPathComponent("tool-calls")
            .appendingPathComponent("adversarial")
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeConfiguredBackend() -> (OllamaBackend, URL) {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-adv-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.1")
        return (backend, baseURL.appendingPathComponent("api/chat"))
    }

    /// Feeds a single NDJSON fixture line (plus a terminal `done:true` line
    /// so the stream closes) through `OllamaBackend.parseResponseStream` and
    /// returns the emitted events.
    ///
    /// Uses the public `generate(...)` path so tests exercise the same
    /// stack that real consumers use. If Agent D's parser changes the
    /// entry-point name, only this helper needs updating.
    private func replayFixture(_ fixtureLine: String) async throws -> [GenerationEvent] {
        let (backend, chatURL) = makeConfiguredBackend()
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        // Append a terminal done-chunk so the NDJSON parser completes cleanly.
        // Preserve the fixture's trailing newline if present — malformed
        // fixtures rely on that shape.
        let fixtureData = Data(fixtureLine.utf8)
        let terminalLine = Data(#"{"model":"llama3.1","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"# .utf8 + Array("\n".utf8))

        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: [fixtureData, terminalLine], statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "trigger", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    // MARK: - Corpus walker

    func test_adversarialCorpus_matchesExpectedOutcomes() async throws {
        try XCTSkipUnless(
            ollamaToolCallingIsWired,
            "Ollama tool-call emission is wired by Agent D's PR. This test un-skips once that PR merges and `supportsToolCalling` flips to true."
        )

        let fm = FileManager.default
        let dir = corpusDirectory()
        XCTAssertTrue(fm.fileExists(atPath: dir.path), "corpus directory missing: \(dir.path)")

        let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let fixtureFiles = entries.filter {
            $0.pathExtension == "json"
                && !$0.lastPathComponent.hasSuffix(".expected.json")
        }

        XCTAssertGreaterThanOrEqual(fixtureFiles.count, 15, "corpus must contain 15+ adversarial fixtures; found \(fixtureFiles.count)")

        for fixtureURL in fixtureFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let base = fixtureURL.deletingPathExtension().lastPathComponent
            let expectedURL = dir.appendingPathComponent("\(base).expected.json")
            let fixtureLine = try String(contentsOf: fixtureURL, encoding: .utf8)
            let expectedData = try Data(contentsOf: expectedURL)
            let expected = try JSONDecoder().decode(Expected.self, from: expectedData)

            let events: [GenerationEvent]
            do {
                events = try await replayFixture(fixtureLine)
            } catch {
                XCTFail("\(base): replay threw \(error)")
                continue
            }

            let toolCalls = events.compactMap { event -> ToolCall? in
                if case .toolCall(let call) = event { return call }
                return nil
            }

            if expected.should_emit {
                XCTAssertFalse(
                    toolCalls.isEmpty,
                    "\(base): expected .toolCall emission, got none; notes=\(expected.notes ?? "")"
                )
                if let name = expected.tool_name, let first = toolCalls.first {
                    XCTAssertEqual(first.toolName, name, "\(base): tool_name mismatch")
                }
                if let needle = expected.arguments_contains, let first = toolCalls.first {
                    XCTAssertTrue(
                        first.arguments.contains(needle),
                        "\(base): arguments '\(first.arguments)' does not contain '\(needle)'"
                    )
                }
                if let expectedCount = expected.expected_call_count {
                    XCTAssertEqual(
                        toolCalls.count,
                        expectedCount,
                        "\(base): expected \(expectedCount) tool calls, got \(toolCalls.count)"
                    )
                }
            } else {
                XCTAssertTrue(
                    toolCalls.isEmpty,
                    "\(base): expected no .toolCall emission, got \(toolCalls.count); notes=\(expected.notes ?? "")"
                )
            }
        }
    }

    // MARK: - Focused sabotage target

    /// This test is named to match the sabotage target declared in the PR body.
    /// It isolates the `arguments-as-object` case so a targeted sabotage of
    /// the re-serialisation path fails only this test (not the entire corpus
    /// walker).
    func test_arguments_as_object_gets_restringified() async throws {
        try XCTSkipUnless(
            ollamaToolCallingIsWired,
            "Pending Agent D's parser landing."
        )

        let dir = corpusDirectory()
        let fixtureLine = try String(
            contentsOf: dir.appendingPathComponent("arguments-as-object.json"),
            encoding: .utf8
        )
        let events = try await replayFixture(fixtureLine)

        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event { return call }
            return nil
        }

        XCTAssertEqual(toolCalls.count, 1, "arguments-as-object must still emit one ToolCall")
        let call = toolCalls[0]
        XCTAssertEqual(call.toolName, "get_weather")
        // ToolCall.arguments is typed as String in the public API. The
        // adversarial line emits arguments as a JSON object; the parser
        // must re-serialise to a string. Contract: the re-stringified form
        // must parse as a JSON object containing `city: "Paris"`.
        let data = Data(call.arguments.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(parsed?["city"] as? String, "Paris", "re-serialised arguments must round-trip as valid JSON")
    }
}
#endif
