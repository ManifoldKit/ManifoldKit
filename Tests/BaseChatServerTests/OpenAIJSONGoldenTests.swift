import XCTest

final class OpenAIJSONGoldenTests: XCTestCase {
    func testDecodesOpenAIRequestWithMessagesToolsAndStreamOptions() throws {
        let json = #"""
        {
          "model": "demo-model",
          "messages": [
            { "role": "system", "content": "You are concise." },
            { "role": "user", "content": "Weather in Paris?" }
          ],
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "get_weather",
                "description": "Return weather.",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "city": { "type": "string" }
                  },
                  "required": ["city"]
                }
              }
            }
          ],
          "stream": true,
          "stream_options": { "include_usage": true }
        }
        """#

        let request = try OpenAIJSONGolden.decode(OpenAIChatRequestGolden.self, from: json)

        XCTAssertEqual(request.model, "demo-model")
        XCTAssertEqual(request.messages.map(\.role), ["system", "user"])
        XCTAssertEqual(request.messages.last?.content, "Weather in Paris?")
        XCTAssertEqual(request.tools?.first?.type, "function")
        XCTAssertEqual(request.tools?.first?.function.name, "get_weather")
        XCTAssertEqual(request.stream, true)
        XCTAssertEqual(request.streamOptions?.includeUsage, true)
    }

    func testTokenChunkJSONShape() throws {
        let json = #"""
        {
          "id": "chatcmpl-test",
          "object": "chat.completion.chunk",
          "created": 1710000000,
          "model": "demo-model",
          "choices": [
            { "index": 0, "delta": { "content": "Hel" }, "finish_reason": null }
          ]
        }
        """#

        let chunk = try OpenAIJSONGolden.decode(OpenAIChatChunkGolden.self, from: json)

        XCTAssertEqual(chunk.object, "chat.completion.chunk")
        XCTAssertEqual(chunk.choices.first?.delta.content, "Hel")
        XCTAssertNil(chunk.choices.first?.finishReason)
        XCTAssertNil(chunk.usage)
    }

    func testToolCallDeltaJSONShape() throws {
        let json = #"""
        {
          "id": "chatcmpl-test",
          "object": "chat.completion.chunk",
          "created": 1710000000,
          "model": "demo-model",
          "choices": [
            {
              "index": 0,
              "delta": {
                "tool_calls": [
                  {
                    "index": 0,
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "get_weather",
                      "arguments": "{\"city\":"
                    }
                  }
                ]
              },
              "finish_reason": null
            }
          ]
        }
        """#

        let chunk = try OpenAIJSONGolden.decode(OpenAIChatChunkGolden.self, from: json)
        let toolCall = chunk.choices.first?.delta.toolCalls?.first

        XCTAssertEqual(toolCall?.index, 0)
        XCTAssertEqual(toolCall?.id, "call_1")
        XCTAssertEqual(toolCall?.type, "function")
        XCTAssertEqual(toolCall?.function?.name, "get_weather")
        XCTAssertEqual(toolCall?.function?.arguments, "{\"city\":")
    }

    func testUsageJSONShape() throws {
        let json = #"""
        {
          "id": "chatcmpl-test",
          "object": "chat.completion.chunk",
          "created": 1710000000,
          "model": "demo-model",
          "choices": [],
          "usage": {
            "prompt_tokens": 7,
            "completion_tokens": 5,
            "total_tokens": 12
          }
        }
        """#

        let chunk = try OpenAIJSONGolden.decode(OpenAIChatChunkGolden.self, from: json)

        XCTAssertEqual(chunk.usage?.promptTokens, 7)
        XCTAssertEqual(chunk.usage?.completionTokens, 5)
        XCTAssertEqual(chunk.usage?.totalTokens, 12)
    }
}
