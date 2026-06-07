#if CloudSaaS || Ollama
import XCTest
@testable import ManifoldCloud
@testable import ManifoldCloudCore
@testable import ManifoldInference

/// Parameterised contract suite over every cloud backend.
///
/// Phase 2/B/i shipped the scaffold with inline fixtures. Phase 2/B/ii
/// (this PR) replaces the inline payloads with on-disk fixtures under
/// `Tests/Fixtures/backends/<provider>/<scenario>/{request.json,
/// response.sse, expected.jsonl}`. The on-disk format is what
/// `scripts/record-fixture.sh` will write when capturing against a live
/// endpoint, so the recording workflow now has a stable target. Each
/// fixture is also scanned by `FixtureRedactionAuditTest` so credentials
/// cannot leak in.
///
/// Each scenario is capability-gated: assertions only run for backends
/// whose `BackendCapabilities` claim the relevant feature. As Phase 3
/// lands the remaining adapters, each backend is added to `participants`
/// (with its own fixture tree) and the existing scenarios light up
/// automatically.
final class InferenceBackendContractTests: XCTestCase {

    // MARK: - Participants

    /// Static description of one backend's contract surface. The handler
    /// is the canonical surface for per-payload classification; the
    /// finalizer for stream-termination semantics. `fixtureDirectory` is
    /// the on-disk subdirectory under `Tests/Fixtures/backends/` that
    /// holds this participant's scenario corpus.
    struct Participant {
        let label: String
        let fixtureDirectory: String
        let handler: CloudPayloadHandler
        let finalizer: any StreamFinalizer
        let capabilities: BackendCapabilities
        /// Wire format used by this participant's `response.<ext>` fixture.
        /// SSE participants ship `response.sse` (with `data:` prefix);
        /// NDJSON participants ship `response.ndjson` (one JSON object per
        /// line, no prefix). Encoded as an enum so the loader picks the
        /// right framing convention.
        let wireFormat: WireFormat

        enum WireFormat {
            case sse
            case ndjson

            var fileName: String {
                switch self {
                case .sse: return "response.sse"
                case .ndjson: return "response.ndjson"
                }
            }
        }
    }

    #if CloudSaaS
    private static let openAIParticipant = Participant(
        label: "openai.chat_completions",
        fixtureDirectory: "openai",
        handler: .openAI,
        finalizer: OpenAIDoneSentinelFinalizer(),
        // Synthetic capability set: matches what `OpenAIBackend` advertises
        // for a streaming + tools + usage-counting model. Mirrors the real
        // backend's declaration without coupling this test to the live one.
        capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 128_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            supportsNativeJSONMode: true,
            cancellationStyle: .cooperative,
            supportsTokenCounting: true,
            memoryStrategy: .external,
            maxOutputTokens: 16_384,
            supportsStreaming: true,
            isRemote: true,
            supportsKVCachePersistence: false,
            supportsGrammarConstrainedSampling: false,
            supportsThinking: false,
            supportsVision: true,
            streamsToolCallArguments: true,
            supportsParallelToolCalls: true,
            supportsGuidedStructuredOutput: true,
            sharesMLXProcessResources: false
        ),
        wireFormat: .sse
    )
    #endif

    /// OpenAI Responses API participant (Phase 3/Responses). Routes
    /// through ``CloudPayloadHandler/openAIResponses`` for the
    /// extractEvents surface — for the Responses wire shape that means
    /// the stateless `delta` fallback projection (the named-dispatch
    /// path runs through `OpenAIResponsesStreamEventExtractor`, covered
    /// by its own parity suite). The contract scenarios here exercise
    /// usage extraction and finalizer detection, which the stateless
    /// handler covers end-to-end. Tool-call and structured-output
    /// witness shapes are asserted via the witness label below.
    private static let openAIResponsesParticipant = Participant(
        label: "openai.responses",
        fixtureDirectory: "openai_responses",
        handler: .openAIResponses,
        finalizer: OpenAIResponsesEventFinalizer(),
        capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 200_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            supportsNativeJSONMode: false,
            cancellationStyle: .cooperative,
            // The Responses extractor emits `.usage` from
            // `response.completed` payloads. The stateless handler in
            // this suite reads from the same payload shape, so usage
            // extraction lights up.
            supportsTokenCounting: true,
            memoryStrategy: .external,
            maxOutputTokens: 16_384,
            supportsStreaming: true,
            isRemote: true,
            supportsKVCachePersistence: false,
            supportsGrammarConstrainedSampling: false,
            supportsThinking: true,
            supportsVision: false,
            streamsToolCallArguments: true,
            supportsParallelToolCalls: true,
            supportsGuidedStructuredOutput: true,
            sharesMLXProcessResources: false
        ),
        wireFormat: .sse
    )

    #if Ollama
    private static let ollamaParticipant = Participant(
        label: "ollama.chat",
        fixtureDirectory: "ollama",
        handler: .ollama,
        finalizer: OllamaDoneFlagFinalizer(),
        // Synthetic capability set mirroring `OllamaBackend.capabilities`'s
        // pre-probe defaults. Vision is gated separately on the wire
        // (Ollama's `images[]` field is message-level base-64, not a
        // content part) and is not exercised by the current fixture corpus.
        capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP, .topK, .repeatPenalty],
            maxContextTokens: 128_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            supportsNativeJSONMode: true,
            cancellationStyle: .cooperative,
            supportsTokenCounting: true,
            memoryStrategy: .external,
            maxOutputTokens: 128_000,
            supportsStreaming: true,
            isRemote: true,
            supportsKVCachePersistence: false,
            supportsGrammarConstrainedSampling: false,
            supportsThinking: false,
            supportsVision: false,
            streamsToolCallArguments: false,
            supportsParallelToolCalls: true,
            supportsGuidedStructuredOutput: false,
            sharesMLXProcessResources: false
        ),
        wireFormat: .ndjson
    )
    #endif

    private static let claudeParticipant = Participant(
        label: "anthropic.messages",
        fixtureDirectory: "claude",
        handler: .claude,
        finalizer: ClaudeMessageStopFinalizer(),
        // Synthetic capability set matching what `ClaudeBackend` advertises
        // for a streaming + tools + extended-thinking model. Claude reports
        // usage split across `message_start` (prompt) and `message_delta`
        // (completion), so the contract test's per-frame `extractUsage`
        // walk would only see one half at a time — `supportsTokenCounting`
        // is false here so the `usage/basic` scenario skips that assertion
        // and runs only the finalizer + streaming checks against the same
        // fixture. The `ClaudeStreamEventExtractor` parity tests cover the
        // merged-usage emission separately.
        capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 200_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            supportsNativeJSONMode: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 8192,
            supportsStreaming: true,
            isRemote: true,
            supportsKVCachePersistence: false,
            supportsGrammarConstrainedSampling: false,
            supportsThinking: true,
            supportsVision: true,
            streamsToolCallArguments: true,
            supportsParallelToolCalls: true,
            supportsGuidedStructuredOutput: false,
            sharesMLXProcessResources: false
        ),
        wireFormat: .sse
    )

    private static let participants: [Participant] = {
        var list: [Participant] = []
        #if CloudSaaS
        list.append(openAIParticipant)
        list.append(openAIResponsesParticipant)
        list.append(claudeParticipant)
        #endif
        #if Ollama
        list.append(ollamaParticipant)
        #endif
        return list
    }()

    // MARK: - Scenarios (capability-gated)

    func test_streaming_simplePrompt_emitsTokenInOrder() throws {
        for p in Self.participants where p.capabilities.supportsStreaming {
            let payloads = try loadPayloads(participant: p, scenario: "streaming/simple-prompt")
            var emitted: [GenerationEvent] = []
            for payload in payloads {
                emitted.append(contentsOf: p.handler.extractEvents(from: payload))
            }
            XCTAssertFalse(emitted.isEmpty, "[\(p.label)] expected at least one event")
            // Compare against the on-disk expected projection.
            let fixture = try fixtureURL(for: p, scenario: "streaming/simple-prompt", file: "expected.jsonl")
            XCTAssertEventsMatch(actual: emitted, fixtureURL: fixture)
        }
    }

    func test_usage_basic_extractsPromptAndCompletionTokens() throws {
        for p in Self.participants where p.capabilities.supportsTokenCounting {
            let payloads = try loadPayloads(participant: p, scenario: "usage/basic")
            // Find the payload that carries usage; the handler API exposes
            // usage extraction per-frame.
            var observed: (promptTokens: Int?, completionTokens: Int?)?
            for payload in payloads {
                if let u = p.handler.extractUsage(from: payload) {
                    observed = u
                    break
                }
            }
            XCTAssertNotNil(observed, "[\(p.label)] expected usage struct")
            XCTAssertGreaterThan(observed?.promptTokens ?? 0, 0, "[\(p.label)] promptTokens")
            XCTAssertGreaterThan(observed?.completionTokens ?? 0, 0, "[\(p.label)] completionTokens")
        }
    }

    /// Tool-call event emission today lives in `OpenAIBackend.processToolCalls...`,
    /// not in the per-payload handler. The Phase 2/B/ii widen of
    /// `SSECloudBackend` to consume the adapter will hoist that logic into
    /// the `ToolCallShape` witness so this scenario can assert at the
    /// handler level. Until then we assert that:
    ///   (a) the adapter's witness label is the expected shape, and
    ///   (b) the fixture corpus carries a `tool-calls/simple/` directory so
    ///       a future runtime test has a concrete capture to replay.
    func test_toolCalls_simple_witnessShapeIsDeclared() throws {
        for p in Self.participants where p.capabilities.supportsToolCalling {
            // Verify the fixture exists; gives the future runtime test a
            // concrete file to load without re-deriving paths.
            _ = try fixtureURL(for: p, scenario: "tool-calls/simple", file: p.wireFormat.fileName)
            switch p.label {
            case "openai.chat_completions":
                let shape = OpenAIDeltaToolCalls()
                XCTAssertEqual(shape.shapeName, "openai.delta")
            #if CloudSaaS
            case "openai.responses":
                let shape = OpenAIResponsesItemIdToolCalls()
                XCTAssertEqual(shape.shapeName, "openai_responses.item_id")
            #endif
            #if Ollama
            case "ollama.chat":
                let shape = OllamaWholeToolCalls()
                XCTAssertEqual(shape.shapeName, "ollama.whole")
            #endif
            case "anthropic.messages":
                let shape = AnthropicBlockToolCalls()
                XCTAssertEqual(shape.shapeName, "anthropic.block")
            default:
                XCTFail("[\(p.label)] no witness shape assertion declared")
            }
        }
    }

    func test_finalizer_recognizesTerminalFrame() throws {
        for p in Self.participants {
            let payloads = try loadPayloads(participant: p, scenario: "usage/basic")
            // The terminal frame of the `usage/basic` scenario carries both
            // `finish_reason` and `usage`; either signals completion to the
            // OpenAI finalizer.
            var sawComplete = false
            for payload in payloads {
                guard let data = payload.data(using: .utf8) else { continue }
                if case .streamComplete = p.finalizer.finalize(frame: data) {
                    sawComplete = true
                    break
                }
            }
            XCTAssertTrue(sawComplete, "[\(p.label)] finalizer failed to recognise a terminal frame in the `usage/basic` corpus")
        }
    }

    // MARK: - Error sanitization (footgun audit class A — #1623)

    /// A poison probe used only to prove the *negative* path: backends that
    /// declare no in-stream error fixture must return `nil` from
    /// `extractStreamError` for any input, confirming the skip below can't
    /// mask a newly-introduced (and unsanitized) handler error path.
    private static let poisonProbe =
        #"{"type":"error","error":{"message":"boom https://evil.example eyJabc"}}"#

    /// Every cloud backend that surfaces an upstream error *inside* a 200-OK
    /// stream must route that text through `CloudErrorSanitizer` before it can
    /// reach the UI. The footgun audit (2026-06-05) found the sanitize
    /// invariant wired into only the non-2xx HTTP branch (class A — "two paths,
    /// one guard"); #1630 added the `sanitized*` construction chokepoint. This
    /// scenario is the per-family conformance proof that the chokepoint is
    /// actually on every backend's in-stream error path.
    ///
    /// Only Claude and the OpenAI Responses adapter expose an in-stream handler
    /// error path (`extractStreamError`); OpenAI Chat Completions and Ollama
    /// surface server errors at the HTTP-status boundary in `SSECloudBackend`
    /// (covered by `CloudBackendErrorSanitizedFactoryTests`). Participants
    /// without an `error/in-stream` fixture are asserted to genuinely lack the
    /// path rather than silently skipped.
    ///
    /// The fixture payloads carry a JWT, a URL, and >256 chars of padding. The
    /// redaction audit (`FixtureRedactionAuditTest`) has no JWT/URL pattern, so
    /// the poison is safe to commit while still exercising the sanitizer's JWT
    /// redaction, URL redaction, and length cap.
    func test_inStreamServerError_isSanitizedAtHandler() throws {
        for p in Self.participants {
            let url = try fixtureURL(for: p, scenario: "error/in-stream", file: "event.json")
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTAssertNil(
                    p.handler.extractStreamError(from: Self.poisonProbe),
                    "[\(p.label)] declares no in-stream error fixture, but extractStreamError returned a non-nil error — a new handler error path was added without a sanitization conformance fixture"
                )
                continue
            }
            let payload = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let surfaced = p.handler.extractStreamError(from: payload) else {
                XCTFail("[\(p.label)] in-stream error fixture did not surface an error through extractStreamError")
                continue
            }
            let text = (surfaced as? CloudBackendError)?.errorDescription
                ?? String(describing: surfaced)
            XCTAssertFalse(text.contains("eyJ"), "[\(p.label)] surfaced error leaked a JWT")
            XCTAssertFalse(text.contains("://"), "[\(p.label)] surfaced error leaked a URL scheme")
            XCTAssertFalse(
                text.lowercased().contains("evil.example"),
                "[\(p.label)] surfaced error leaked a URL host"
            )
            // Sanitizer caps the upstream text at 256 chars + ellipsis; the
            // error-description wrapper adds a short fixed prefix.
            XCTAssertLessThan(
                text.count, 400,
                "[\(p.label)] surfaced error was not length-bounded — sanitizer cap not applied"
            )
        }
    }

    // MARK: - Fixture loading

    /// Reads `response.sse` from the participant's scenario directory and
    /// returns the JSON payload strings (one per `data: …` line, skipping
    /// the `[DONE]` sentinel and any blank lines). This is the same shape
    /// the per-payload handler API consumes after the SSE transport has
    /// parsed framing.
    private func loadPayloads(participant: Participant, scenario: String) throws -> [String] {
        let url = try fixtureURL(for: participant, scenario: scenario, file: participant.wireFormat.fileName)
        let raw = try String(contentsOf: url, encoding: .utf8)
        switch participant.wireFormat {
        case .sse:
            var payloads: [String] = []
            for line in raw.components(separatedBy: "\n") {
                // SSE event payload lines start with `data: `. Strip the
                // prefix and skip the `[DONE]` sentinel.
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst("data: ".count))
                if payload == "[DONE]" { continue }
                payloads.append(payload)
            }
            return payloads
        case .ndjson:
            // NDJSON: one JSON object per line, no prefix, no sentinel.
            return raw.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
    }

    private func fixtureURL(
        for participant: Participant,
        scenario: String,
        file: String,
        filePath: StaticString = #filePath
    ) throws -> URL {
        let root = try Self.locateFixturesRoot(filePath: filePath)
        return root
            .appendingPathComponent("backends")
            .appendingPathComponent(participant.fixtureDirectory)
            .appendingPathComponent(scenario)
            .appendingPathComponent(file)
    }

    /// Walks up from `#filePath` until a `Tests/Fixtures/` directory is
    /// found. Mirrors the upwalk pattern used by other audit tests so
    /// invocation works regardless of cwd.
    private static func locateFixturesRoot(filePath: StaticString) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/Fixtures")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "InferenceBackendContractTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"
        ])
    }
}
#endif
