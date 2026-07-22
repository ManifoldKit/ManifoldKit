import XCTest
import ManifoldInference
@testable import ManifoldFoundation
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore

/// Phase 1b/B contract suite for ``CloudMessageEncoder``.
///
/// Parameterised over every supported provider case. Asserts:
/// 1. simple message encoding lands in the provider-valid wire shape;
/// 2. tool definitions encode through the provider's `tools[]` envelope.
///
/// Tool-result encoding and Claude cache-breakpoint annotation used to live
/// on `CloudMessageEncoder` too (`encodeToolResults` / `annotateCacheBreakpoints`),
/// but those two methods were orphaned public surface — the live turn path
/// encodes tool results through `encodeMessages(toolAwareHistory:)` and does
/// Claude cache-control inline in `ClaudeBackend.buildRequest`. Both were
/// removed 2026-07-22 (issue #2128 inert-surface sweep); their live
/// equivalents stay covered by the per-backend tool-calling suites and
/// `ClaudePromptCacheTests`.
///
/// These tests are the floor `CloudPayloadHandlerContractTests` (Worker C)
/// builds on — together they form the cross-backend contract layer the
/// plan promises will replace the per-provider parallel suites.
final class CloudMessageEncoderContractTests: XCTestCase {

    // MARK: - Fixtures

    /// Every provider case the enum supports. Phase 2 will add more
    /// cases (Gemini, Bedrock, GROQ) — keep this list as the canonical
    /// source for test parameterisation.
    private static var allCases: [(name: String, encoder: CloudMessageEncoder)] {
        var cases: [(String, CloudMessageEncoder)] = []
        cases.append(("openAI", .openAI))
        cases.append(("openAIResponses", .openAIResponses))
        cases.append(("claude", .claude))
        cases.append(("ollama", .ollama))
        return cases
    }

    private func simpleTool() -> ToolDefinition {
        ToolDefinition(
            name: "get_weather",
            description: "Get the current weather for a location",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "location": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("location")]),
            ])
        )
    }

    // MARK: - encodeMessages

    /// A lone-prompt encode produces a single `user` turn for every
    /// provider, regardless of dialect.
    func test_encodeMessages_lonePrompt_singleUserTurn_allProviders() throws {
        for (name, encoder) in Self.allCases {
            let messages = encoder.encodeMessages(
                systemPrompt: nil,
                prompt: "hello",
                structuredHistory: nil,
                toolAwareHistory: nil,
                plainHistory: nil
            )
            XCTAssertEqual(messages.count, 1, "\(name): expected single message for lone prompt")
            XCTAssertEqual(messages.first?["role"] as? String, "user", "\(name): lone prompt must surface as a user turn")
            XCTAssertEqual(messages.first?["content"] as? String, "hello", "\(name): lone prompt content must round-trip verbatim")
        }
    }

    /// System prompts route in two ways: OpenAI/OpenAIResponses/Ollama
    /// inline a `{role: "system"}` entry; Claude expects the caller to
    /// hoist the system prompt to a top-level body field, so the encoder
    /// must NOT prepend a system entry.
    func test_encodeMessages_withSystemPrompt_inlinesForChatProviders_omitsForClaude() throws {
        for (name, encoder) in Self.allCases {
            let messages = encoder.encodeMessages(
                systemPrompt: "you are helpful",
                prompt: "hi",
                structuredHistory: nil,
                toolAwareHistory: nil,
                plainHistory: nil
            )
            switch encoder {
            case .claude:
                XCTAssertEqual(messages.first?["role"] as? String, "user",
                               "\(name): Claude must NOT inline a system entry — caller hoists it to the top-level system field")
            default:
                XCTAssertEqual(messages.first?["role"] as? String, "system",
                               "\(name): expected an inline system entry as the first message")
                XCTAssertEqual(messages.first?["content"] as? String, "you are helpful")
            }
        }
    }

    /// Plain `(role, content)` history is the legacy fallback and must
    /// round-trip on every provider when no richer history is supplied.
    func test_encodeMessages_plainHistory_passthrough_allProviders() throws {
        for (name, encoder) in Self.allCases {
            let history: [(role: String, content: String)] = [
                (role: "user", content: "ping"),
                (role: "assistant", content: "pong"),
            ]
            let messages = encoder.encodeMessages(
                systemPrompt: nil,
                prompt: "",
                structuredHistory: nil,
                toolAwareHistory: nil,
                plainHistory: history
            )
            XCTAssertEqual(messages.count, 2, "\(name): plain history must produce one entry per turn")
            XCTAssertEqual(messages[0]["content"] as? String, "ping", "\(name): plain history content round-trip")
            XCTAssertEqual(messages[1]["content"] as? String, "pong", "\(name): plain history content round-trip")
        }
    }

    // MARK: - encodeTools

    /// `tools[]` envelope per provider:
    /// - OpenAI/OpenAIResponses/Ollama: `{type: "function", function: {name, description, parameters}}`
    /// - Claude: `{name, description, input_schema}`
    func test_encodeTools_producesProviderEnvelope_allProviders() throws {
        for (name, encoder) in Self.allCases {
            let encoded = encoder.encodeTools([simpleTool()])
            XCTAssertEqual(encoded.count, 1, "\(name): one tool in, one tool out")
            let entry = encoded[0]

            switch encoder {
            case .claude:
                XCTAssertEqual(entry["name"] as? String, "get_weather", "\(name): top-level name")
                XCTAssertEqual(entry["description"] as? String, "Get the current weather for a location")
                XCTAssertNotNil(entry["input_schema"], "\(name): Anthropic uses input_schema, not parameters")
                XCTAssertNil(entry["type"], "\(name): Anthropic shape has no top-level type")
            default:
                XCTAssertEqual(entry["type"] as? String, "function", "\(name): OpenAI-shape tools require type:function")
                let function = entry["function"] as? [String: Any]
                XCTAssertEqual(function?["name"] as? String, "get_weather", "\(name): function.name")
                XCTAssertNotNil(function?["parameters"], "\(name): OpenAI-shape uses parameters, not input_schema")
            }
        }
    }

    /// Empty tool list short-circuits to an empty array.
    func test_encodeTools_emptyList_returnsEmpty_allProviders() throws {
        for (name, encoder) in Self.allCases {
            let encoded = encoder.encodeTools([])
            XCTAssertTrue(encoded.isEmpty, "\(name): empty input must produce empty output")
        }
    }
}
