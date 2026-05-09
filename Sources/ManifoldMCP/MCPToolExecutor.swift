import Foundation
import ManifoldInference

public final class MCPToolExecutor: ToolExecutor, @unchecked Sendable {
    public let definition: ToolDefinition
    private let remoteToolName: String
    private let serverDisplayName: String
    private let callTool: @Sendable (_ toolName: String, _ arguments: JSONSchemaValue) async throws -> JSONSchemaValue?
    private let toolApprovalDidSucceed: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var requiresApprovalValue: Bool

    public init(definition: ToolDefinition) {
        self.definition = definition
        self.remoteToolName = definition.name
        self.serverDisplayName = definition.name
        self.callTool = { name, _ in
            throw MCPError.toolNotFound(name)
        }
        self.toolApprovalDidSucceed = nil
        self.requiresApprovalValue = true
    }

    internal init(
        definition: ToolDefinition,
        serverDisplayName: String,
        remoteToolName: String,
        requiresApproval: Bool,
        toolApprovalDidSucceed: (@Sendable () async -> Void)? = nil,
        callTool: @Sendable @escaping (_ toolName: String, _ arguments: JSONSchemaValue) async throws -> JSONSchemaValue?
    ) {
        self.definition = definition
        self.serverDisplayName = serverDisplayName
        self.remoteToolName = remoteToolName
        self.toolApprovalDidSucceed = toolApprovalDidSucceed
        self.callTool = callTool
        self.requiresApprovalValue = requiresApproval
    }

    public var requiresApproval: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requiresApprovalValue
    }

    public var supportsConcurrentDispatch: Bool { true }

    internal func setRequiresApproval(_ value: Bool) {
        lock.lock()
        requiresApprovalValue = value
        lock.unlock()
    }

    public func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        do {
            try Task.checkCancellation()
            await toolApprovalDidSucceed?()
            let response = try await callTool(remoteToolName, arguments)
            try Task.checkCancellation()
            let parsed = Self.parseResult(response)
            let wrapped = MCPContentSanitizer.wrapForUntrustedSurface(
                Self.sanitize(parsed.content),
                serverDisplayName: serverDisplayName
            )
            return ToolResult(callId: "", content: wrapped, errorKind: parsed.errorKind)
        } catch is CancellationError {
            return ToolResult(callId: "", content: "cancelled by user", errorKind: .cancelled)
        } catch let error as MCPError {
            return ToolResult(
                callId: "",
                content: Self.sanitize(Self.message(for: error)),
                errorKind: errorKind(for: error)
            )
        } catch {
            return ToolResult(callId: "", content: Self.sanitize(error.localizedDescription), errorKind: .permanent)
        }
    }

    private static func parseResult(_ value: JSONSchemaValue?) -> (content: String, errorKind: ToolResult.ErrorKind?) {
        guard let value else { return ("", nil) }
        guard case .object(let object) = value else {
            return (jsonString(from: value), nil)
        }

        let content = renderContent(from: object["content"] ?? value)
        if case .bool(true)? = object["isError"] {
            if case .string(let rawKind)? = object["errorKind"],
               let kind = ToolResult.ErrorKind(rawValue: rawKind) {
                return (content, kind)
            }
            return (content, .permanent)
        }
        return (content, nil)
    }

    private static func renderContent(from value: JSONSchemaValue) -> String {
        if case .string(let string) = value {
            return string
        }
        if case .array(let values) = value {
            let text = values.compactMap { item -> String? in
                guard case .object(let object) = item else { return nil }
                guard case .string(let type)? = object["type"], type == "text" else { return nil }
                guard case .string(let segment)? = object["text"] else { return nil }
                return segment
            }.joined(separator: "\n")
            if text.isEmpty == false { return text }
        }
        return jsonString(from: value)
    }

    private static func message(for error: MCPError) -> String {
        switch error {
        case .transportClosed:
            return "transport closed"
        case .transportFailure(let message),
             .authorizationFailed(let message),
             .dcrFailed(let message),
             .malformedMetadata(let message),
             .failed(let message):
            return message
        case .protocolError(_, let message, _):
            return message
        case .requestTimeout:
            return "request timed out"
        case .unsupportedProtocolVersion(let server, let client):
            return "unsupported protocol version server=\(server) client=\(client)"
        case .authorizationRequired:
            return "authorization required"
        case .issuerMismatch(let expected, let actual):
            return "issuer mismatch expected=\(expected.absoluteString) actual=\(actual.absoluteString)"
        case .ssrfBlocked(let url):
            return "ssrf blocked \(url.absoluteString)"
        case .tooManyTools(let count):
            return "too many tools (\(count))"
        case .toolNotFound(let name):
            return "tool not found: \(name)"
        case .oversizeContent(let bytes):
            return "oversize content \(bytes)"
        case .oversizeMessage(let bytes):
            return "oversize message \(bytes)"
        case .backgroundedDuringDispatch:
            return "backgrounded during dispatch"
        case .cancelled:
            return "cancelled by user"
        case .networkUnavailable:
            return "network unavailable"
        case .unauthorized:
            return "unauthorized"
        }
    }

    private static func sanitize(_ value: String, limit: Int = 8_192) -> String {
        let filtered = value.unicodeScalars.filter { scalar in
            if CharacterSet.controlCharacters.contains(scalar) {
                return scalar.value == 10 || scalar.value == 13 || scalar.value == 9
            }
            return true
        }
        let string = String(String.UnicodeScalarView(filtered))
        if string.count <= limit {
            return string
        }
        return String(string.prefix(limit))
    }

    private static func jsonString(from value: JSONSchemaValue) -> String {
        do {
            let data = try JSONEncoder().encode(value)
            if let string = String(data: data, encoding: .utf8) {
                return string
            }
        } catch {
            Log.inference.warning("MCPToolExecutor: failed to encode structured content as JSON string")
        }
        return ""
    }
}
