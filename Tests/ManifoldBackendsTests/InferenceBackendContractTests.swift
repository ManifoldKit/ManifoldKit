#if CloudSaaS
import XCTest
@testable import ManifoldCloud
@testable import ManifoldCloudCore
@testable import ManifoldInference

/// Parameterised contract suite over every cloud backend.
///
/// Phase 2/B/i ships the scaffold and one OpenAI participant. Each scenario
/// is capability-gated: assertions only run for backends whose
/// `BackendCapabilities` claim the relevant feature. As Phase 3 lands the
/// remaining adapters, each backend is added to `participants` and the
/// existing scenarios light up automatically.
///
/// Fixtures live under `Tests/Fixtures/backends/<provider>/...` and are
/// validated by `FixtureRedactionAuditTest`. Phase 2/B/i uses inline
/// fixtures so the scaffold is runnable before the recording-from-live
/// workflow is bedded in (a `scripts/record-fixture.sh` capture against
/// a real OpenAI endpoint is the follow-up step that converts these
/// inline fixtures to on-disk ones).
final class InferenceBackendContractTests: XCTestCase {

    // MARK: - Participants

    /// Static description of one backend's contract surface. The handler
    /// is the canonical surface for per-payload classification; the
    /// finalizer for stream-termination semantics.
    struct Participant {
        let label: String
        let handler: CloudPayloadHandler
        let finalizer: any StreamFinalizer
        let capabilities: BackendCapabilities
    }

    private static let openAIParticipant = Participant(
        label: "openai.chat_completions",
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
        )
    )

    private static let participants: [Participant] = [openAIParticipant]

    // MARK: - Scenarios (capability-gated)

    func test_streaming_simplePrompt_emitsTokenInOrder() {
        for p in Self.participants where p.capabilities.supportsStreaming {
            let payload = inlineFixture_streamingSimplePrompt(for: p)
            let events = p.handler.extractEvents(from: payload)
            XCTAssertFalse(events.isEmpty, "[\(p.label)] expected at least one event")
            if case .token(let text) = events.first {
                XCTAssertFalse(text.isEmpty, "[\(p.label)] first token was empty")
            } else {
                XCTFail("[\(p.label)] expected first event to be .token, got \(String(describing: events.first))")
            }
        }
    }

    func test_usage_basic_extractsPromptAndCompletionTokens() {
        for p in Self.participants where p.capabilities.supportsTokenCounting {
            let payload = inlineFixture_usageBasic(for: p)
            let usage = p.handler.extractUsage(from: payload)
            XCTAssertNotNil(usage, "[\(p.label)] expected usage struct")
            XCTAssertGreaterThan(usage?.promptTokens ?? 0, 0, "[\(p.label)] promptTokens")
            XCTAssertGreaterThan(usage?.completionTokens ?? 0, 0, "[\(p.label)] completionTokens")
        }
    }

    /// Tool-call event emission today lives in `OpenAIBackend.processToolCalls...`,
    /// not in the per-payload handler. The Phase 2/B/ii widen of
    /// `SSECloudBackend` to consume the adapter will hoist that logic into
    /// the `ToolCallShape` witness so this scenario can assert at the
    /// handler level. Until then we assert only that the witness label is
    /// the expected shape — a structural contract on the adapter's
    /// composition rather than a per-payload behavioural assertion.
    func test_toolCalls_simple_witnessShapeIsDeclared() {
        for p in Self.participants where p.capabilities.supportsToolCalling {
            // The adapter's `toolCallShape` is the contract; the actual
            // per-payload extraction lives on the backend until Phase
            // 2/B/ii.
            switch p.label {
            case "openai.chat_completions":
                let shape = OpenAIDeltaToolCalls()
                XCTAssertEqual(shape.shapeName, "openai.delta")
            default:
                XCTFail("[\(p.label)] no witness shape assertion declared")
            }
        }
    }

    func test_finalizer_recognizesTerminalFrame() {
        for p in Self.participants {
            let payload = inlineFixture_terminalFrame(for: p)
            let signal = p.finalizer.finalize(frame: Data(payload.utf8))
            guard case .streamComplete = signal else {
                XCTFail("[\(p.label)] finalizer failed to recognise terminal frame: \(String(describing: signal))")
                continue
            }
        }
    }

    // MARK: - Inline fixtures
    //
    // Per-participant payload shapes. Phase 2/B/ii will replace these with
    // on-disk fixtures recorded against a real provider; for now they keep
    // the scaffold runnable and exercise the parameterised structure.

    private func inlineFixture_streamingSimplePrompt(for p: Participant) -> String {
        switch p.label {
        case "openai.chat_completions":
            return #"{"choices":[{"delta":{"content":"Hello"}}]}"#
        default:
            return ""
        }
    }

    private func inlineFixture_usageBasic(for p: Participant) -> String {
        switch p.label {
        case "openai.chat_completions":
            return #"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":48,"total_tokens":60}}"#
        default:
            return ""
        }
    }

    private func inlineFixture_toolCallSimple(for p: Participant) -> String {
        switch p.label {
        case "openai.chat_completions":
            return #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","function":{"name":"get_weather","arguments":"{\"city\":\"SF\"}"}}]}}]}"#
        default:
            return ""
        }
    }

    private func inlineFixture_terminalFrame(for p: Participant) -> String {
        switch p.label {
        case "openai.chat_completions":
            return #"{"choices":[{"finish_reason":"stop","delta":{}}]}"#
        default:
            return ""
        }
    }
}
#endif
