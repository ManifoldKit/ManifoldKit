import Foundation
import ManifoldInference

internal enum MCPRequestID: Hashable, Sendable, CustomStringConvertible {
    case int(Int)
    case string(String)

    var description: String {
        switch self {
        case .int(let value): return "\(value)"
        case .string(let value): return value
        }
    }
}

internal struct MCPJSONRPCErrorObject: Sendable, Equatable {
    let code: Int
    let message: String
    let data: JSONSchemaValue?
}

internal enum MCPJSONRPCMessage: Sendable, Equatable {
    case request(id: MCPRequestID, method: String, params: JSONSchemaValue?)
    case notification(method: String, params: JSONSchemaValue?)
    case result(id: MCPRequestID, result: JSONSchemaValue?)
    case error(id: MCPRequestID, error: MCPJSONRPCErrorObject)
}

internal struct MCPJSONRPCCodec: Sendable {
    let maxMessageBytes: Int
    let maxJSONNestingDepth: Int

    init(maxMessageBytes: Int, maxJSONNestingDepth: Int) {
        self.maxMessageBytes = maxMessageBytes
        self.maxJSONNestingDepth = maxJSONNestingDepth
    }

    func encode(_ message: MCPJSONRPCMessage) throws -> Data {
        let object = try encodeObject(from: message)
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    func decode(_ data: Data) throws -> MCPJSONRPCMessage {
        if data.count > maxMessageBytes {
            throw MCPError.oversizeMessage(data.count)
        }

        let object = try JSONSerialization.jsonObject(with: data)
        try validateNestingDepth(of: object)

        guard let envelope = object as? [String: Any] else {
            throw MCPError.protocolError(code: -32600, message: "JSON-RPC message must be an object", data: nil)
        }

        guard (envelope["jsonrpc"] as? String) == "2.0" else {
            throw MCPError.protocolError(code: -32600, message: "Unsupported JSON-RPC version", data: nil)
        }

        let id = try parseID(from: envelope["id"])
        let method = envelope["method"] as? String

        if let method {
            let params = try parseValue(from: envelope["params"])
            if let id {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }

        if let id {
            if envelope.keys.contains("result") {
                let result = try parseValue(from: envelope["result"])
                return .result(id: id, result: result)
            }

            if let errorEnvelope = envelope["error"] as? [String: Any],
               let code = errorEnvelope["code"] as? Int,
               let message = errorEnvelope["message"] as? String {
                let data = try parseValue(from: errorEnvelope["data"])
                return .error(id: id, error: MCPJSONRPCErrorObject(code: code, message: message, data: data))
            }
        }

        throw MCPError.protocolError(code: -32600, message: "Malformed JSON-RPC envelope", data: nil)
    }

    private func encodeObject(from message: MCPJSONRPCMessage) throws -> [String: Any] {
        switch message {
        case .request(let id, let method, let params):
            var object: [String: Any] = [
                "jsonrpc": "2.0",
                "id": encodeID(id),
                "method": method,
            ]
            if let params {
                object["params"] = try encodeJSONValue(params)
            }
            return object
        case .notification(let method, let params):
            var object: [String: Any] = [
                "jsonrpc": "2.0",
                "method": method,
            ]
            if let params {
                object["params"] = try encodeJSONValue(params)
            }
            return object
        case .result(let id, let result):
            var object: [String: Any] = [
                "jsonrpc": "2.0",
                "id": encodeID(id),
            ]
            object["result"] = try encodeJSONValue(result ?? .null)
            return object
        case .error(let id, let error):
            var errorObject: [String: Any] = [
                "code": error.code,
                "message": error.message,
            ]
            if let data = error.data {
                errorObject["data"] = try encodeJSONValue(data)
            }
            return [
                "jsonrpc": "2.0",
                "id": encodeID(id),
                "error": errorObject,
            ]
        }
    }

    private func parseID(from raw: Any?) throws -> MCPRequestID? {
        guard let raw else { return nil }
        if let intID = raw as? Int {
            return .int(intID)
        }
        if let stringID = raw as? String {
            return .string(stringID)
        }
        throw MCPError.protocolError(code: -32600, message: "Invalid JSON-RPC id", data: nil)
    }

    private func encodeID(_ id: MCPRequestID) -> Any {
        switch id {
        case .int(let value): return value
        case .string(let value): return value
        }
    }

    private func parseValue(from raw: Any?) throws -> JSONSchemaValue? {
        guard let raw else { return nil }
        return try convertToJSONSchemaValue(raw)
    }

    private func convertToJSONSchemaValue(_ raw: Any) throws -> JSONSchemaValue {
        switch raw {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            return .number(value.doubleValue)
        case let value as String:
            return .string(value)
        case let values as [Any]:
            return .array(try values.map(convertToJSONSchemaValue))
        case let values as [String: Any]:
            var object: [String: JSONSchemaValue] = [:]
            object.reserveCapacity(values.count)
            for (key, value) in values {
                object[key] = try convertToJSONSchemaValue(value)
            }
            return .object(object)
        default:
            throw MCPError.protocolError(code: -32602, message: "Unsupported JSON value", data: nil)
        }
    }

    private func encodeJSONValue(_ value: JSONSchemaValue) throws -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return try values.map(encodeJSONValue)
        case .object(let values):
            var object: [String: Any] = [:]
            object.reserveCapacity(values.count)
            for (key, value) in values {
                object[key] = try encodeJSONValue(value)
            }
            return object
        }
    }

    private func validateNestingDepth(of root: Any) throws {
        func depth(of value: Any, current: Int) throws {
            if current > maxJSONNestingDepth {
                throw MCPError.malformedMetadata("JSON depth exceeded max of \(maxJSONNestingDepth)")
            }

            if let values = value as? [Any] {
                for nested in values {
                    try depth(of: nested, current: current + 1)
                }
                return
            }

            if let values = value as? [String: Any] {
                for nested in values.values {
                    try depth(of: nested, current: current + 1)
                }
            }
        }

        try depth(of: root, current: 1)
    }
}
