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
/// properties (string/number/boolean/enum) — `ManifoldMCP` does not validate that
/// shape itself; the host's form renderer is expected to reject or best-effort-render
/// anything else (and can always answer `.decline` for an unsupported shape).
public struct MCPElicitationRequest: Sendable, Equatable {
    /// Human-readable prompt describing what the server is asking for.
    public let message: String
    /// A JSON Schema (as `JSONSchemaValue`) restricted by spec to a flat object of
    /// primitive-typed properties. The host's form renderer maps this to UI
    /// controls (string→TextField, boolean→Toggle, enum→Picker, etc.).
    public let requestedSchema: JSONSchemaValue

    public init(message: String, requestedSchema: JSONSchemaValue) {
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
    init(params: JSONSchemaValue?) throws {
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

        self.message = message
        self.requestedSchema = requestedSchema
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
