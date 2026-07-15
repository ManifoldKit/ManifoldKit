import Foundation
import ManifoldInference

// MARK: - Wire types (MCP 2025-06-18 `sampling/createMessage`)

/// A server-initiated request for the client to run a completion through the local
/// engine, per the MCP `sampling/createMessage` method (spec 2025-06-18).
///
/// `ManifoldMCP` is engine-agnostic: it parses this off the wire and hands it to the
/// host-supplied `MCPClientConfiguration.samplingHandler` closure, which is the only
/// place that talks to `InferenceService`. This type is `public` because that handler
/// closure crosses the package boundary into host app code.
///
/// **v1 defaults** (documented here, not enforced by this type):
/// - `modelPreferences` hints are parsed but MAY be ignored — the reference handler
///   uses whichever model the host app already has active. A future version can wire
///   hints into model selection without changing this type.
/// - The request/response shape is non-streaming: the host handler is expected to
///   run the full generation and return one `MCPSamplingResult`, even if the
///   underlying engine streams internally.
public struct MCPSamplingRequest: Sendable, Equatable {
    public struct Message: Sendable, Equatable {
        public enum Role: String, Sendable, Equatable {
            case user
            case assistant
        }

        public enum Content: Sendable, Equatable {
            case text(String)
            case image(data: String, mimeType: String)
        }

        public let role: Role
        public let content: Content

        public init(role: Role, content: Content) {
            self.role = role
            self.content = content
        }
    }

    /// Server-supplied model selection hints. Advisory only — see the v1-defaults
    /// note on ``MCPSamplingRequest``.
    public struct ModelPreferences: Sendable, Equatable {
        public let hintNames: [String]
        public let costPriority: Double?
        public let speedPriority: Double?
        public let intelligencePriority: Double?

        public init(
            hintNames: [String] = [],
            costPriority: Double? = nil,
            speedPriority: Double? = nil,
            intelligencePriority: Double? = nil
        ) {
            self.hintNames = hintNames
            self.costPriority = costPriority
            self.speedPriority = speedPriority
            self.intelligencePriority = intelligencePriority
        }
    }

    public let messages: [Message]
    public let modelPreferences: ModelPreferences?
    public let systemPrompt: String?
    public let maxTokens: Int?
    public let temperature: Double?
    public let stopSequences: [String]

    public init(
        messages: [Message],
        modelPreferences: ModelPreferences? = nil,
        systemPrompt: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        stopSequences: [String] = []
    ) {
        self.messages = messages
        self.modelPreferences = modelPreferences
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stopSequences = stopSequences
    }
}

/// The client's answer to a `sampling/createMessage` request, produced by the host's
/// `samplingHandler` closure and serialized back to the server as a JSON-RPC result.
///
/// Budget/rate-limiting is deliberately NOT this type's concern, or `ManifoldMCP`'s —
/// see the security note on `MCPClientConfiguration.samplingHandler`. A host that
/// wires up sampling without its own approval/budget gate lets any connected MCP
/// server spend inference budget on demand.
public struct MCPSamplingResult: Sendable, Equatable {
    public let role: MCPSamplingRequest.Message.Role
    public let content: MCPSamplingRequest.Message.Content
    public let model: String
    public let stopReason: String?

    public init(
        role: MCPSamplingRequest.Message.Role,
        content: MCPSamplingRequest.Message.Content,
        model: String,
        stopReason: String? = nil
    ) {
        self.role = role
        self.content = content
        self.model = model
        self.stopReason = stopReason
    }
}

// MARK: - JSONSchemaValue <-> wire type conversion

extension MCPSamplingRequest {
    /// Parses the `params` object of a `sampling/createMessage` JSON-RPC request.
    init(params: JSONSchemaValue?) throws {
        guard case .object(let object) = params else {
            throw MCPError.protocolError(
                code: -32602,
                message: "sampling/createMessage requires object params",
                data: nil
            )
        }
        guard case .array(let rawMessages)? = object["messages"] else {
            throw MCPError.protocolError(
                code: -32602,
                message: "sampling/createMessage requires a 'messages' array",
                data: nil
            )
        }

        self.messages = try rawMessages.map(Message.init(value:))
        self.modelPreferences = object["modelPreferences"].flatMap(ModelPreferences.init(value:))
        self.systemPrompt = MCPSampling.stringValue(object["systemPrompt"])
        self.maxTokens = MCPSampling.intValue(object["maxTokens"])
        self.temperature = MCPSampling.doubleValue(object["temperature"])
        if case .array(let stops)? = object["stopSequences"] {
            self.stopSequences = stops.compactMap(MCPSampling.stringValue)
        } else {
            self.stopSequences = []
        }
    }
}

extension MCPSamplingRequest.Message {
    init(value: JSONSchemaValue) throws {
        guard case .object(let object) = value,
              case .string(let roleRaw)? = object["role"],
              let role = Role(rawValue: roleRaw) else {
            throw MCPError.protocolError(
                code: -32602,
                message: "sampling message requires a valid 'role'",
                data: nil
            )
        }
        self.role = role
        self.content = try Content(value: object["content"])
    }
}

extension MCPSamplingRequest.Message.Content {
    init(value: JSONSchemaValue?) throws {
        guard case .object(let object) = value,
              case .string(let type)? = object["type"] else {
            throw MCPError.protocolError(
                code: -32602,
                message: "sampling message content requires a 'type'",
                data: nil
            )
        }

        switch type {
        case "text":
            guard case .string(let text)? = object["text"] else {
                throw MCPError.protocolError(code: -32602, message: "text content requires 'text'", data: nil)
            }
            self = .text(text)
        case "image":
            guard case .string(let data)? = object["data"],
                  case .string(let mimeType)? = object["mimeType"] else {
                throw MCPError.protocolError(
                    code: -32602,
                    message: "image content requires 'data' and 'mimeType'",
                    data: nil
                )
            }
            self = .image(data: data, mimeType: mimeType)
        default:
            throw MCPError.protocolError(code: -32602, message: "unsupported content type '\(type)'", data: nil)
        }
    }

    var jsonRPCValue: JSONSchemaValue {
        switch self {
        case .text(let text):
            return .object(["type": .string("text"), "text": .string(text)])
        case .image(let data, let mimeType):
            return .object([
                "type": .string("image"),
                "data": .string(data),
                "mimeType": .string(mimeType),
            ])
        }
    }
}

extension MCPSamplingRequest.ModelPreferences {
    init?(value: JSONSchemaValue) {
        guard case .object(let object) = value else { return nil }
        var hintNames: [String] = []
        if case .array(let hints)? = object["hints"] {
            hintNames = hints.compactMap { hint -> String? in
                guard case .object(let hintObject) = hint else { return nil }
                return MCPSampling.stringValue(hintObject["name"])
            }
        }
        self.init(
            hintNames: hintNames,
            costPriority: MCPSampling.doubleValue(object["costPriority"]),
            speedPriority: MCPSampling.doubleValue(object["speedPriority"]),
            intelligencePriority: MCPSampling.doubleValue(object["intelligencePriority"])
        )
    }
}

extension MCPSamplingResult {
    /// Encodes this result as the `result` payload of the JSON-RPC response.
    var jsonRPCResult: JSONSchemaValue {
        var object: [String: JSONSchemaValue] = [
            "role": .string(role.rawValue),
            "content": content.jsonRPCValue,
            "model": .string(model),
        ]
        if let stopReason {
            object["stopReason"] = .string(stopReason)
        }
        return .object(object)
    }
}

private enum MCPSampling {
    static func stringValue(_ value: JSONSchemaValue?) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }

    static func intValue(_ value: JSONSchemaValue?) -> Int? {
        switch value {
        case .integer(let value): return Int(value)
        case .number(let value):
            // `Int(Double)` is the non-failable rounding init and TRAPS on
            // out-of-range/NaN/Inf. The JSON codec decodes every wire number as
            // `.number(Double)` (never `.integer`), so this arm is the live path for
            // maxTokens off an untrusted server — `Int(exactly:)` never traps; an
            // out-of-range/NaN/Inf value just drops the field instead of crashing.
            return Int(exactly: value.rounded())
        default: return nil
        }
    }

    static func doubleValue(_ value: JSONSchemaValue?) -> Double? {
        switch value {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }
}
