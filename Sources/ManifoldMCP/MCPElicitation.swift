import Foundation
import ManifoldInference

// MARK: - Wire types (MCP 2025-06-18 `elicitation/create`)

/// A server-initiated request for the client to collect structured input from the
/// user, per the MCP `elicitation/create` method (spec 2025-06-18).
///
/// `ManifoldMCP` is UI-free: it parses this off the wire and hands it to the
/// host-supplied `MCPClientConfiguration.elicitationHandler` closure, which is the
/// only place that renders a form and returns the user's answer. This type is
/// `public` because that handler closure crosses the package boundary into host app
/// code.
///
/// The spec restricts `requestedSchema` to a flat JSON Schema object of primitive
/// properties (string/number/boolean/enum). `MCPClient` validates that shape via
/// `MCPElicitationRequest.isSupportedSchema(_:)` before this request ever reaches the
/// host handler — an unsupported shape is auto-declined (see
/// `MCPClient.makeServerRequestHandler`), per #1926's resolution. The host's form
/// renderer should still defensively handle any shape it doesn't recognize.
///
/// **Server identity (#2284 review, blocker 1)**: `MCPClientConfiguration.elicitationHandler`
/// is one closure shared across every connected server, so `serverID` is the ONLY
/// signal the host has to answer "which server is asking, and do I trust it enough to
/// show this prompt?" per the security note on `MCPClientConfiguration.elicitationHandler`.
/// Without it, a low-trust server B can send a message indistinguishable from a
/// trusted server A's prompt (e.g. spoofing a password re-entry dialog) and the host
/// has nothing to key a warning or block on. `serverID` is always the connecting
/// `MCPServerDescriptor.id`, supplied by `MCPClient` — never parsed off the wire, so a
/// malicious server cannot forge it.
public struct MCPElicitationRequest: Sendable, Equatable {
    /// The connecting `MCPServerDescriptor.id` of the server that issued this request.
    /// Supplied by `MCPClient` from the descriptor used to `connect(_:)`, never from
    /// server-controlled wire data — the host uses this to look up which server is
    /// asking (display name, trust level) and must render that identity as part of
    /// the prompt (see the security note on `MCPClientConfiguration.elicitationHandler`).
    public let serverID: UUID
    /// Human-readable prompt describing what the server is asking for.
    public let message: String
    /// A JSON Schema (as `JSONSchemaValue`) restricted by spec to a flat object of
    /// primitive-typed properties. The host's form renderer maps this to UI
    /// controls (string→TextField, boolean→Toggle, enum→Picker, etc.).
    public let requestedSchema: JSONSchemaValue

    public init(serverID: UUID, message: String, requestedSchema: JSONSchemaValue) {
        self.serverID = serverID
        self.message = message
        self.requestedSchema = requestedSchema
    }
}

/// The client's answer to an `elicitation/create` request, produced by the host's
/// `elicitationHandler` closure and serialized back to the server as a JSON-RPC
/// result.
///
/// `.decline` and `.cancel` must always be available to the user — see the security
/// note on `MCPClientConfiguration.elicitationHandler`.
public struct MCPElicitationResult: Sendable, Equatable {
    /// MCP spec action vocabulary for `elicitation/create` responses.
    public enum Action: String, Sendable, Equatable {
        /// The user filled the form and submitted it — `content` carries their answer.
        case accept
        /// The user was shown the prompt and explicitly declined to answer.
        case decline
        /// The request was dismissed without a decision (e.g. sheet cancelled, timeout).
        case cancel
    }

    public let action: Action
    /// The user's answer, matching `requestedSchema`. Only meaningful when
    /// `action == .accept`; `nil` for `.decline`/`.cancel`.
    public let content: JSONSchemaValue?

    public init(action: Action, content: JSONSchemaValue? = nil) {
        self.action = action
        self.content = content
    }
}

// MARK: - JSONSchemaValue <-> wire type conversion

extension MCPElicitationRequest {
    /// Parses the `params` object of an `elicitation/create` JSON-RPC request.
    /// `serverID` comes from the connecting `MCPServerDescriptor`, never from `params`
    /// — see the security note on ``MCPElicitationRequest/serverID``.
    init(serverID: UUID, params: JSONSchemaValue?) throws {
        guard case .object(let object) = params else {
            throw MCPError.protocolError(
                code: -32602,
                message: "elicitation/create requires object params",
                data: nil
            )
        }
        guard case .string(let message)? = object["message"] else {
            throw MCPError.protocolError(
                code: -32602,
                message: "elicitation/create requires a 'message' string",
                data: nil
            )
        }
        guard let requestedSchema = object["requestedSchema"] else {
            throw MCPError.protocolError(
                code: -32602,
                message: "elicitation/create requires a 'requestedSchema'",
                data: nil
            )
        }

        // The server-authored prompt renders directly in a user-facing dialog —
        // reuse the same injection-indicator logging already applied to tool
        // metadata (`MCPToolSource.swift`) so an adversarial "message" surfaces in
        // operator logs rather than only in the UI. Logging only; never blocks.
        MCPContentSanitizer.logInjectionIndicators(in: message, field: "elicitation message", toolName: serverID.uuidString)

        self.serverID = serverID
        self.message = message
        self.requestedSchema = requestedSchema
    }

    /// Validates `requestedSchema` against the MCP spec's restriction to a flat JSON
    /// Schema object of primitive-typed properties (string/number/integer/boolean).
    /// `MCPClient.makeServerRequestHandler` calls this before invoking the host's
    /// `elicitationHandler` and auto-declines unsupported shapes (#1926's resolution:
    /// "validate and decline on unsupported shapes") rather than forwarding an
    /// arbitrarily-nested or non-primitive schema to a form renderer that may not
    /// expect one.
    static func isSupportedSchema(_ schema: JSONSchemaValue) -> Bool {
        guard case .object(let object) = schema else { return false }
        guard case .string("object")? = object["type"] else { return false }
        guard case .object(let properties)? = object["properties"] else {
            // No `properties` key: an empty flat object is within the spec's shape.
            return true
        }
        for (_, propertySchema) in properties {
            guard case .object(let propertyObject) = propertySchema else { return false }
            guard case .string(let type)? = propertyObject["type"] else { return false }
            switch type {
            case "string", "number", "integer", "boolean":
                continue
            default:
                return false
            }
        }
        return true
    }
}

extension MCPElicitationResult {
    /// Encodes this result as the `result` payload of the JSON-RPC response.
    var jsonRPCResult: JSONSchemaValue {
        var object: [String: JSONSchemaValue] = ["action": .string(action.rawValue)]
        if let content {
            object["content"] = content
        }
        return .object(object)
    }
}
