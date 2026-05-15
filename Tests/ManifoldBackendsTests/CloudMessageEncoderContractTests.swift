#if CloudSaaS || Ollama
import XCTest
import ManifoldInference
@testable import ManifoldCloud

/// Phase 1b/B contract suite for ``CloudMessageEncoder``.
///
/// Parameterised over every supported provider case. Asserts:
/// 1. simple message encoding lands in the provider-valid wire shape;
/// 2. tool definitions encode through the provider's `tools[]` envelope;
/// 3. tool results encode through the provider's reply shape;
/// 4. `annotateCacheBreakpoints` is a no-op for OpenAI/OpenAIResponses/
///    Ollama and adds explicit `cache_control` markers only for Claude.
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
        #if CloudSaaS
        cases.append(("openAI", .openAI))
        cases.append(("openAIResponses", .openAIResponses))
        cases.append(("claude", .claude))
        #endif
        #if Ollama
        cases.append(("ollama", .ollama))
        #endif
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
            #if CloudSaaS
            case .claude:
                XCTAssertEqual(messages.first?["role"] as? String, "user",
                               "\(name): Claude must NOT inline a system entry — caller hoists it to the top-level system field")
            #endif
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
            #if CloudSaaS
            case .claude:
                XCTAssertEqual(entry["name"] as? String, "get_weather", "\(name): top-level name")
                XCTAssertEqual(entry["description"] as? String, "Get the current weather for a location")
                XCTAssertNotNil(entry["input_schema"], "\(name): Anthropic uses input_schema, not parameters")
                XCTAssertNil(entry["type"], "\(name): Anthropic shape has no top-level type")
            #endif
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

    // MARK: - encodeToolResults

    /// Tool results encode per provider:
    /// - OpenAI / Ollama: one `{role:"tool", tool_call_id, content}` per result.
    /// - OpenAI Responses: one `{type:"function_call_output", call_id, output}` per result.
    /// - Claude: a single user turn whose `content` is an array of
    ///   `{type:"tool_result", tool_use_id, content}` blocks.
    func test_encodeToolResults_producesProviderShape_allProviders() throws {
        let results = [
            ToolResult(callId: "call_1", content: "{\"temperature\": 72}"),
            ToolResult(callId: "call_2", content: "{\"forecast\": \"sunny\"}"),
        ]

        for (name, encoder) in Self.allCases {
            let encoded = encoder.encodeToolResults(results)

            switch encoder {
            #if CloudSaaS
            case .claude:
                XCTAssertEqual(encoded.count, 1, "\(name): Claude bundles all tool results into one user turn")
                XCTAssertEqual(encoded.first?["role"] as? String, "user", "\(name): Claude tool_result turns are role=user")
                let blocks = encoded.first?["content"] as? [[String: Any]]
                XCTAssertEqual(blocks?.count, 2, "\(name): one content block per ToolResult")
                XCTAssertEqual(blocks?.first?["type"] as? String, "tool_result")
                XCTAssertEqual(blocks?.first?["tool_use_id"] as? String, "call_1",
                               "\(name): Claude uses tool_use_id (not tool_call_id)")
            case .openAIResponses:
                XCTAssertEqual(encoded.count, 2, "\(name): Responses emits one function_call_output per result")
                XCTAssertEqual(encoded[0]["type"] as? String, "function_call_output")
                XCTAssertEqual(encoded[0]["call_id"] as? String, "call_1",
                               "\(name): Responses uses call_id (not tool_call_id)")
                XCTAssertEqual(encoded[0]["output"] as? String, "{\"temperature\": 72}")
            #endif
            default:
                // .openAI, .ollama
                XCTAssertEqual(encoded.count, 2, "\(name): one tool turn per result")
                XCTAssertEqual(encoded[0]["role"] as? String, "tool", "\(name): Chat-Completions-style uses role=tool")
                XCTAssertEqual(encoded[0]["tool_call_id"] as? String, "call_1")
                XCTAssertEqual(encoded[0]["content"] as? String, "{\"temperature\": 72}")
            }
        }
    }

    /// Empty result list short-circuits to an empty array on every provider.
    func test_encodeToolResults_empty_returnsEmpty_allProviders() throws {
        for (name, encoder) in Self.allCases {
            let encoded = encoder.encodeToolResults([])
            XCTAssertTrue(encoded.isEmpty, "\(name): empty in → empty out")
        }
    }

    // MARK: - annotateCacheBreakpoints

    /// Cache annotation is a no-op everywhere except Claude. Calling it
    /// on non-Claude providers must not mutate the inputs.
    func test_annotateCacheBreakpoints_noOpForNonClaudeProviders() throws {
        for (name, encoder) in Self.allCases {
            guard case .claude = encoder else {
                var systemBlock: Any? = "you are helpful"
                var toolEntries: [[String: Any]] = [
                    ["name": "t1", "description": "d1"],
                    ["name": "t2", "description": "d2"],
                ]
                let originalSystem = systemBlock as? String
                let originalToolCount = toolEntries.count

                encoder.annotateCacheBreakpoints(
                    plan: CacheBreakpointPlan(maxBreakpoints: 4, cacheSystem: true, cacheToolsTail: true),
                    systemPrompt: "you are helpful",
                    systemBlock: &systemBlock,
                    toolEntries: &toolEntries
                )

                XCTAssertEqual(systemBlock as? String, originalSystem,
                               "\(name): non-Claude providers must NOT mutate systemBlock")
                XCTAssertEqual(toolEntries.count, originalToolCount,
                               "\(name): non-Claude providers must NOT add or remove tool entries")
                for (idx, entry) in toolEntries.enumerated() {
                    XCTAssertNil(entry["cache_control"],
                                 "\(name): non-Claude providers must NOT add cache_control to tool entries (entry idx=\(idx))")
                }
                continue
            }
        }
    }

    /// Claude with both cacheSystem + cacheToolsTail must rewrite the
    /// system block to a content-array form (so it has a slot for
    /// `cache_control`) AND tag the last tool entry.
    #if CloudSaaS
    func test_annotateCacheBreakpoints_claude_addsExplicitMarkers() throws {
        var systemBlock: Any? = "you are helpful"
        var toolEntries: [[String: Any]] = [
            ["name": "t1", "description": "d1"],
            ["name": "t2", "description": "d2"],
        ]

        CloudMessageEncoder.claude.annotateCacheBreakpoints(
            plan: CacheBreakpointPlan(maxBreakpoints: 4, cacheSystem: true, cacheToolsTail: true),
            systemPrompt: "you are helpful",
            systemBlock: &systemBlock,
            toolEntries: &toolEntries
        )

        // System prompt should now be a content-array carrying cache_control.
        let systemArray = try XCTUnwrap(systemBlock as? [[String: Any]],
            "Claude must rewrite the system field to a content-block array so it can carry cache_control")
        XCTAssertEqual(systemArray.count, 1)
        XCTAssertEqual(systemArray[0]["type"] as? String, "text")
        XCTAssertEqual(systemArray[0]["text"] as? String, "you are helpful")
        XCTAssertNotNil(systemArray[0]["cache_control"], "system block must carry cache_control when plan.cacheSystem=true")

        // Last tool entry must be tagged; the earlier ones must not be.
        XCTAssertNil(toolEntries[0]["cache_control"], "non-tail tool entries must NOT carry cache_control")
        XCTAssertNotNil(toolEntries[1]["cache_control"], "tail tool entry must carry cache_control when plan.cacheToolsTail=true")
    }

    /// `maxBreakpoints` caps how many markers get attached even when the
    /// plan asks for more.
    func test_annotateCacheBreakpoints_claude_respectsMaxBreakpoints() throws {
        var systemBlock: Any? = "you are helpful"
        var toolEntries: [[String: Any]] = [["name": "t1", "description": "d1"]]

        CloudMessageEncoder.claude.annotateCacheBreakpoints(
            plan: CacheBreakpointPlan(maxBreakpoints: 1, cacheSystem: true, cacheToolsTail: true),
            systemPrompt: "you are helpful",
            systemBlock: &systemBlock,
            toolEntries: &toolEntries
        )

        XCTAssertNotNil(systemBlock as? [[String: Any]], "first breakpoint consumed by system block")
        XCTAssertNil(toolEntries[0]["cache_control"],
                     "second breakpoint must be suppressed once maxBreakpoints is exhausted")
    }
    #endif
}
#endif
