#if Server
import Foundation
import XCTest

enum OpenAIJSONGolden {
    static let decoder = JSONDecoder()

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        do {
            return try decoder.decode(T.self, from: Data(json.utf8))
        } catch {
            XCTFail("Failed to decode golden JSON: \(error)", file: file, line: line)
            throw error
        }
    }

    static func encode<T: Encodable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        do {
            let data = try encoder.encode(value)
            return String(decoding: data, as: UTF8.self)
        } catch {
            XCTFail("Failed to encode golden JSON: \(error)", file: file, line: line)
            throw error
        }
    }
}

struct OpenAIChatRequestGolden: Codable, Equatable {
    struct Message: Codable, Equatable {
        var role: String
        var content: String?
        var toolCallID: String?
        var toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case toolCallID = "tool_call_id"
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCall: Codable, Equatable {
        struct Function: Codable, Equatable {
            var name: String
            var arguments: String
        }

        var id: String
        var type: String
        var function: Function
    }

    struct Tool: Codable, Equatable {
        struct Function: Codable, Equatable {
            var name: String
            var description: String?
            var parameters: JSONValue
        }

        var type: String
        var function: Function
    }

    struct StreamOptions: Codable, Equatable {
        var includeUsage: Bool

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    var model: String
    var messages: [Message]
    var tools: [Tool]?
    var stream: Bool?
    var streamOptions: StreamOptions?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case stream
        case streamOptions = "stream_options"
    }
}

struct OpenAIChatChunkGolden: Codable, Equatable {
    struct Choice: Codable, Equatable {
        struct Delta: Codable, Equatable {
            struct ToolCall: Codable, Equatable {
                struct Function: Codable, Equatable {
                    var name: String?
                    var arguments: String?
                }

                var index: Int
                var id: String?
                var type: String?
                var function: Function?
            }

            var role: String?
            var content: String?
            var toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case role
                case content
                case toolCalls = "tool_calls"
            }
        }

        var index: Int
        var delta: Delta
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Codable, Equatable {
        var promptTokens: Int
        var completionTokens: Int
        var totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    var id: String
    var object: String
    var created: Int
    var model: String
    var choices: [Choice]
    var usage: Usage?
}

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

#endif
