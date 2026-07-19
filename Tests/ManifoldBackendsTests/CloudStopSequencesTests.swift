import XCTest
import Foundation
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Wire-contract tests for user-settable stop sequences (#1944, D1).
///
/// Each cloud SaaS encoder forwards ``GenerationConfig/stopSequences`` to its
/// provider under the provider's own key — OpenAI Chat Completions `stop`,
/// Anthropic `stop_sequences` — and OMITS the key entirely when the caller left
/// stops unset (empty), so payloads for existing callers stay byte-identical.
///
/// The OpenAI **Responses** API is the exception: it does not support a
/// stop-sequence parameter (sending `stop` returns 400 "Unknown parameter:
/// 'stop'"), so `OpenAIResponsesBackend` never emits one — verified below.
///
/// We drive `buildRequest(...)` directly: the field insertion is a pure
/// payload-construction concern, so no live HTTP round-trip is required.
final class CloudStopSequencesTests: XCTestCase {

    private func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody, "request must carry an httpBody")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any],
            "request body did not parse as JSON object"
        )
    }

    // MARK: - OpenAI Chat Completions: "stop"

    func test_openAI_includesStop_whenSet() throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://openai.test")!,
            apiKey: "sk-test",
            modelName: "gpt-4o"
        )

        let request = try backend.buildRequest(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig(stopSequences: ["</s>", "User:"]),
            hints: GenerationRuntimeHints()
        )

        let json = try jsonBody(from: request)
        XCTAssertEqual(json["stop"] as? [String], ["</s>", "User:"])
    }

    func test_openAI_omitsStop_whenEmpty() throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://openai.test")!,
            apiKey: "sk-test",
            modelName: "gpt-4o"
        )

        let request = try backend.buildRequest(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig(),
            hints: GenerationRuntimeHints()
        )

        let json = try jsonBody(from: request)
        XCTAssertNil(json["stop"], "unset stops must not appear on the wire")
    }

    // MARK: - OpenAI Responses: stop is UNSUPPORTED — never emitted

    /// The Responses API rejects a top-level `stop` parameter (400 "Unknown
    /// parameter: 'stop'"), so the backend must NOT send one even when the
    /// caller sets stopSequences — sending an invalid field 400s strict
    /// providers. See OpenAIResponsesBackend's buildRequest comment.
    func test_openAIResponses_neverEmitsStop_evenWhenSet() throws {
        let backend = OpenAIResponsesBackend()
        backend.configure(
            baseURL: URL(string: "https://openai-responses.test")!,
            apiKey: "sk-test",
            modelName: "gpt-5"
        )

        let request = try backend.buildRequest(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig(stopSequences: ["END"]),
            hints: GenerationRuntimeHints()
        )

        let json = try jsonBody(from: request)
        XCTAssertNil(
            json["stop"],
            "Responses API does not support `stop`; sending it 400s"
        )
        XCTAssertNil(
            json["stop_sequences"],
            "Responses API has no stop-sequence field under any name"
        )
    }

    func test_openAIResponses_omitsStop_whenEmpty() throws {
        let backend = OpenAIResponsesBackend()
        backend.configure(
            baseURL: URL(string: "https://openai-responses.test")!,
            apiKey: "sk-test",
            modelName: "gpt-5"
        )

        let request = try backend.buildRequest(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig(),
            hints: GenerationRuntimeHints()
        )

        let json = try jsonBody(from: request)
        XCTAssertNil(json["stop"], "unset stops must not appear on the wire")
    }

    // MARK: - Anthropic Claude: "stop_sequences"

    func test_claude_includesStopSequences_whenSet() throws {
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-ant-test",
            modelName: "claude-sonnet-4-20250514"
        )

        let request = try backend.buildRequest(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig(stopSequences: ["</s>", "\n\nHuman:"]),
            hints: GenerationRuntimeHints()
        )

        let json = try jsonBody(from: request)
        XCTAssertEqual(json["stop_sequences"] as? [String], ["</s>", "\n\nHuman:"])
    }

    func test_claude_omitsStopSequences_whenEmpty() throws {
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-ant-test",
            modelName: "claude-sonnet-4-20250514"
        )

        let request = try backend.buildRequest(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig(),
            hints: GenerationRuntimeHints()
        )

        let json = try jsonBody(from: request)
        XCTAssertNil(json["stop_sequences"], "unset stops must not appear on the wire")
    }
}
