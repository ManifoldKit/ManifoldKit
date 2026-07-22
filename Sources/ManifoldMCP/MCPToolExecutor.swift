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

    /// Default UTF-8 byte ceiling applied to sanitized tool output when no
    /// ``ToolOutputPolicy`` limit has been pushed in by the owning registry.
    static let defaultOutputByteLimit = 8_192

    /// UTF-8 byte ceiling for sanitized tool output. Seeded from the owning
    /// ``ToolRegistry``'s ``ToolOutputPolicy/maxBytes`` at registration time so
    /// the transport-boundary truncation respects the host's configured policy
    /// instead of a hardcoded constant. Guarded by `lock`.
    private var outputByteLimitValue: Int = MCPToolExecutor.defaultOutputByteLimit

    /// Preview/test seam only — **not the wired execution path**.
    ///
    /// This zero-dependency initializer builds an executor whose `callTool`
    /// closure unconditionally throws ``MCPError/toolNotFound(_:)``, so invoking
    /// the returned executor always fails at call time. It exists so a
    /// `ToolDefinition` can be wrapped into a `ToolExecutor` for SwiftUI
    /// previews, `ToolRegistry` shape tests, and schema round-trips without
    /// standing up a live MCP transport. The real path is the internal
    /// `init(definition:serverDisplayName:remoteToolName:requiresApproval:toolApprovalDidSucceed:callTool:)`,
    /// which `MCPToolSource` uses to bind the executor to a live server call.
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

    /// Pushes the owning registry's output-size policy into this executor so
    /// the transport-boundary truncation in ``sanitize(_:limit:)`` matches the
    /// configured ``ToolOutputPolicy/maxBytes``. A non-positive limit is
    /// ignored (the executor keeps the 8 KB default) — `0` would otherwise
    /// erase every tool result before the registry's own policy could act.
    internal func setOutputByteLimit(_ limit: Int) {
        guard limit > 0 else { return }
        lock.lock()
        outputByteLimitValue = limit
        lock.unlock()
    }

    private var outputByteLimit: Int {
        lock.lock()
        defer { lock.unlock() }
        return outputByteLimitValue
    }

    public func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        do {
            try Task.checkCancellation()
            await toolApprovalDidSucceed?()
            let response = try await callTool(remoteToolName, arguments)
            try Task.checkCancellation()
            let parsed = parseResult(response)
            let wrapped = MCPContentSanitizer.wrapForUntrustedSurface(
                sanitize(parsed.content),
                serverDisplayName: serverDisplayName
            )
            return ToolResult(
                callId: "",
                content: wrapped,
                errorKind: parsed.errorKind,
                structuredContent: parsed.structuredContent
            )
        } catch is CancellationError {
            return ToolResult(callId: "", content: "cancelled by user", errorKind: .cancelled)
        } catch let error as MCPError {
            return ToolResult(
                callId: "",
                content: sanitize(Self.message(for: error)),
                errorKind: errorKind(for: error)
            )
        } catch {
            return ToolResult(callId: "", content: sanitize(error.localizedDescription), errorKind: .permanent)
        }
    }

    /// Instance entry point for ``sanitize(_:limit:)`` that applies the
    /// registry-configured ``outputByteLimit`` and emits a warning when output
    /// is actually truncated — previously a silent data loss.
    private func sanitize(_ value: String) -> String {
        Self.sanitize(value, limit: outputByteLimit, toolName: definition.name)
    }

    private func parseResult(_ value: JSONSchemaValue?) -> (content: String, errorKind: ToolResult.ErrorKind?, structuredContent: [ToolResultPart]?) {
        guard let value else { return ("", nil, nil) }
        guard case .object(let object) = value else {
            return (Self.jsonString(from: value), nil, nil)
        }

        let rendered = renderContent(from: object["content"] ?? value)
        if case .bool(true)? = object["isError"] {
            if case .string(let rawKind)? = object["errorKind"],
               let kind = ToolResult.ErrorKind(rawValue: rawKind) {
                return (rendered.content, kind, rendered.structuredContent)
            }
            return (rendered.content, .permanent, rendered.structuredContent)
        }
        return (rendered.content, nil, rendered.structuredContent)
    }

    /// Renders an MCP `tools/call` `content` value into the model-facing string
    /// **and** preserves non-text blocks (`resource_link`, embedded `resource`,
    /// `image`, `audio`) — both as readable placeholders in the returned string
    /// and as typed ``ToolResultPart`` entries in `structuredContent`.
    ///
    /// Non-text blocks were previously dropped by a `compactMap` keeping only
    /// `type == "text"` (silent data loss, #1927). A non-text block reduced to a
    /// placeholder now emits a warning, mirroring the byte-truncation warning in
    /// ``sanitize(_:limit:toolName:)``.
    private func renderContent(from value: JSONSchemaValue) -> (content: String, structuredContent: [ToolResultPart]?) {
        if case .string(let string) = value {
            return (string, nil)
        }
        guard case .array(let values) = value else {
            return (Self.jsonString(from: value), nil)
        }

        var segments: [String] = []
        var parts: [ToolResultPart] = []
        for item in values {
            guard case .object(let object) = item,
                  case .string(let type)? = object["type"] else {
                // A non-object or untyped block can't be rendered as a typed
                // part; fall back to a JSON dump rather than dropping it.
                segments.append(Self.jsonString(from: item))
                continue
            }
            switch type {
            case "text":
                if case .string(let segment)? = object["text"] {
                    segments.append(segment)
                    parts.append(.text(segment))
                }
            case "resource_link":
                let uri = Self.stringValue(object["uri"]) ?? ""
                let mimeType = Self.stringValue(object["mimeType"])
                segments.append("[resource: \(uri)\(mimeType.map { " (\($0))" } ?? "")]")
                parts.append(.resourceLink(uri: uri, mimeType: mimeType))
                warnReducedToPlaceholder(type)
            case "resource":
                let resource: [String: JSONSchemaValue]
                if case .object(let nested)? = object["resource"] { resource = nested } else { resource = object }
                let uri = Self.stringValue(resource["uri"]) ?? ""
                let text = Self.stringValue(resource["text"])
                if let text {
                    // Embedded text resources can flow straight into the model path.
                    segments.append(text)
                } else {
                    segments.append("[embedded resource: \(uri)]")
                    warnReducedToPlaceholder(type)
                }
                parts.append(.resource(uri: uri, text: text))
            case "image":
                let mimeType = Self.stringValue(object["mimeType"]) ?? "application/octet-stream"
                segments.append("[image]")
                parts.append(.image(mimeType: mimeType))
                warnReducedToPlaceholder(type)
            case "audio":
                let mimeType = Self.stringValue(object["mimeType"]) ?? "application/octet-stream"
                segments.append("[audio]")
                parts.append(.audio(mimeType: mimeType))
                warnReducedToPlaceholder(type)
            default:
                segments.append("[\(type)]")
                parts.append(.unknown(type: type))
                warnReducedToPlaceholder(type)
            }
        }

        let joined = segments.joined(separator: "\n")
        let content = joined.isEmpty ? Self.jsonString(from: value) : joined
        return (content, parts.isEmpty ? nil : parts)
    }

    /// Surfaces a non-text content block being reduced to a textual placeholder
    /// rather than dropping it silently — same convention as the truncation
    /// warning in ``sanitize(_:limit:toolName:)``.
    private func warnReducedToPlaceholder(_ type: String) {
        let toolName = definition.name
        Log.inference.warning(
            "MCPToolExecutor: reduced non-text tool-result block '\(type, privacy: .public)' to a placeholder for '\(toolName, privacy: .public)'; full fidelity preserved in structuredContent"
        )
    }

    private static func stringValue(_ value: JSONSchemaValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
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

    private static func sanitize(
        _ value: String,
        limit: Int = MCPToolExecutor.defaultOutputByteLimit,
        toolName: String? = nil
    ) -> String {
        let filtered = value.unicodeScalars.filter { scalar in
            if CharacterSet.controlCharacters.contains(scalar) {
                return scalar.value == 10 || scalar.value == 13 || scalar.value == 9
            }
            return true
        }
        let string = String(String.UnicodeScalarView(filtered))
        // Compare and truncate by UTF-8 byte count, not grapheme clusters, so
        // multi-byte characters (CJK, emoji) can't be used to smuggle oversized
        // payloads past a grapheme-cluster limit check.
        let byteCount = string.utf8.count
        if byteCount <= limit {
            return string
        }
        // Truncation is real data loss — surface it rather than silently
        // dropping the tail. The model only ever sees the truncated prefix.
        Log.inference.warning(
            "MCPToolExecutor: truncated tool result for '\(toolName ?? "<unknown>", privacy: .public)' from \(byteCount) to \(limit) bytes"
        )
        return String(bytes: Array(string.utf8.prefix(limit)), encoding: .utf8) ?? String(string.prefix(limit / 4))
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
