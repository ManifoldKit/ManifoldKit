import Foundation

// MARK: - ToolDefinition

/// Describes a tool (function) that an inference backend can invoke.
///
/// Backends that set ``BackendCapabilities/supportsToolCalling`` to `true` accept
/// a list of ``ToolDefinition`` values in ``GenerationConfig/tools``.  The backend
/// serialises these into its native tool-schema format (e.g. OpenAI `functions`,
/// Anthropic `tools`, llama.cpp grammar) before sending the request.
///
/// ## Example
/// ```swift
/// let weatherTool = ToolDefinition(
///     name: "get_weather",
///     description: "Returns current weather for a city.",
///     parameters: [
///         "type": "object",
///         "properties": [
///             "city": ["type": "string", "description": "City name"]
///         ],
///         "required": ["city"]
///     ]
/// )
/// ```
public struct ToolDefinition: Sendable, Codable, Equatable, Hashable {

    /// Unique identifier for the tool — the model uses this name in a ``ToolCall``.
    public let name: String

    /// Human-readable description of what the tool does.
    ///
    /// Good descriptions help the model decide when to invoke the tool.
    public let description: String

    /// JSON-Schema-shaped parameter spec, serialised as a generic dictionary.
    ///
    /// Use the standard JSON Schema vocabulary (`"type"`, `"properties"`,
    /// `"required"`, etc.).  The backend is responsible for mapping this to
    /// its own wire format.
    ///
    /// `Codable` is synthesised via a ``JSONSchemaValue`` bridge so the
    /// dictionary round-trips through `Encoder`/`Decoder` without loss.
    public let parameters: JSONSchemaValue

    /// Creates a tool definition.
    ///
    /// - Parameters:
    ///   - name: The tool name the model will use in ``ToolCall/toolName``.
    ///   - description: What the tool does.
    ///   - parameters: A JSON-Schema object describing the tool's arguments.
    public init(name: String, description: String, parameters: JSONSchemaValue = .object([:])) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - JSONSchemaValue

/// A recursive value type that can represent any JSON-Schema document.
///
/// Using a typed enum rather than `[String: Any]` gives `Sendable`, `Codable`,
/// `Equatable`, and `Hashable` conformances without custom boilerplate.
///
/// Backends serialise this to their native wire format (dictionaries, JSON
/// strings, etc.) at the point of use.
public indirect enum JSONSchemaValue: Sendable, Codable, Equatable, Hashable {
    /// A JSON string.
    case string(String)
    /// A JSON number (stored as `Double` to cover both int and float cases).
    case number(Double)
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON null.
    case null
    /// A JSON array.
    case array([JSONSchemaValue])
    /// A JSON object.
    case object([String: JSONSchemaValue])

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONSchemaValue].self) {
            self = .array(arr)
        } else {
            let dict = try container.decode([String: JSONSchemaValue].self)
            self = .object(dict)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .number(let n):
            try container.encode(n)
        case .string(let s):
            try container.encode(s)
        case .array(let arr):
            try container.encode(arr)
        case .object(let dict):
            try container.encode(dict)
        }
    }
}

// MARK: - ToolCall

/// A tool invocation emitted by the model during generation.
///
/// When the backend decides to call a tool, it emits a
/// ``GenerationEvent/toolCall(_:)`` event carrying one of these values.
/// The host application is responsible for executing the tool and
/// returning a ``ToolResult``.
///
/// ```swift
/// for try await event in stream.events {
///     switch event {
///     case .token(let text):
///         appendText(text)
///     case .toolCall(let call):
///         let result = await myToolDispatcher.execute(call)
///         // Feed result back into the conversation …
///     default:
///         break
///     }
/// }
/// ```
public struct ToolCall: Sendable, Codable, Equatable, Hashable {

    /// Opaque identifier assigned by the backend; echoed back in ``ToolResult/callId``.
    public let id: String

    /// The name of the tool to invoke (matches ``ToolDefinition/name``).
    public let toolName: String

    /// JSON-encoded arguments for the tool, as a raw string.
    ///
    /// Decode this with `JSONDecoder` or `JSONSerialization` according to the
    /// schema declared in the corresponding ``ToolDefinition/parameters``.
    public let arguments: String

    /// Creates a tool call.
    ///
    /// - Parameters:
    ///   - id: Backend-assigned call identifier.
    ///   - toolName: The tool name the model chose to invoke.
    ///   - arguments: JSON-encoded argument payload.
    public init(id: String, toolName: String, arguments: String) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
    }
}

// MARK: - ToolResult

/// The outcome of executing a ``ToolCall``.
///
/// Feed this back to the backend (e.g. as an additional message in the
/// conversation history) so the model can incorporate the tool output
/// into its final response.
public struct ToolResult: Sendable, Codable, Equatable, Hashable {

    /// Categorises why a tool call failed.
    ///
    /// ``ToolResult/errorKind`` is `nil` on success. When non-`nil` it classifies
    /// the failure so backends, orchestrators, and UI surfaces can decide whether
    /// to retry, surface a permission prompt, feed the error back to the model,
    /// or abort the loop. The string raw values are stable on the wire.
    ///
    /// ## Vocabulary freeze (1.0)
    ///
    /// All nine cases below are locked for the 1.0 release. Do not add, remove,
    /// or rename cases without a BREAKING CHANGE commit footer — the raw values
    /// are persisted and transmitted on the wire.
    ///
    /// ### Retryability distinctions
    ///
    /// - ``transient`` vs ``cancelled``: `.cancelled` means the user or system
    ///   *explicitly stopped* the call — the model should not retry because
    ///   cancellation was intentional. `.transient` means the tool infrastructure
    ///   encountered a recoverable glitch (network blip, transient overload) and
    ///   the model *may* retry the same call with the same arguments.
    ///
    /// - ``transient`` vs ``permanent``: `.permanent` means the failure is
    ///   structural — retrying with the same inputs will not help (e.g., a
    ///   configuration error, an unsupported operation). `.transient` is its
    ///   retry-eligible counterpart for ephemeral infrastructure failures.
    ///
    /// ### Dispatch vs runtime distinctions
    ///
    /// - ``unknownTool`` vs ``notFound``: `.unknownTool` is a *dispatch-time*
    ///   failure — no registered executor matched the call name, so the tool
    ///   never ran. `.notFound` is a *runtime* failure — the executor ran but the
    ///   resource it looked for (file, record, URL) did not exist.
    public enum ErrorKind: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
        /// Arguments did not parse as JSON or failed schema validation.
        /// Indicates a model-side formatting error; feeding the error back lets
        /// the model self-correct on the next turn.
        case invalidArguments
        /// The caller lacks permission to run the tool (user denied, missing scope).
        /// Surface a permission prompt rather than retrying silently.
        case permissionDenied
        /// The executor ran but a resource it needed (file, record, URL) was absent.
        /// Distinct from ``unknownTool``, which fires before execution begins.
        case notFound
        /// The tool exceeded its time budget.
        /// May be retried if the operation can be made faster or if the budget can be widened.
        case timeout
        /// The tool or an underlying service applied back-pressure.
        /// Retry after a back-off delay; do not change the arguments.
        case rateLimited
        /// The call was explicitly stopped by the user or system before it completed.
        /// The model should not retry — cancellation was intentional, not a glitch.
        case cancelled
        /// A recoverable infrastructure failure (network blip, transient overload).
        /// The model may retry the same call with the same arguments unchanged.
        /// Distinct from ``cancelled`` (explicit stop) and ``permanent`` (structural failure).
        case transient
        /// A structural failure that retrying with the same inputs will not fix.
        /// Report the error to the user; do not loop. Distinct from ``transient``.
        case permanent
        /// No registered executor matched the call name — dispatch failed before execution.
        /// Distinct from ``notFound``, which fires inside a running executor.
        case unknownTool

        /// User-facing, localizable summary for presentation surfaces.
        ///
        /// This deliberately does not replace ``rawValue``: raw values remain
        /// the stable wire/persistence vocabulary, while this string is for UI.
        public var localizedDescription: String {
            switch self {
            case .invalidArguments:
                return String(localized: "tool.error.invalidArguments", defaultValue: "The tool couldn't understand those details.")
            case .permissionDenied:
                return String(localized: "tool.error.permissionDenied", defaultValue: "Permission is required to use this tool.")
            case .notFound:
                return String(localized: "tool.error.notFound", defaultValue: "The requested item couldn't be found.")
            case .timeout:
                return String(localized: "tool.error.timeout", defaultValue: "The tool took too long to respond.")
            case .rateLimited:
                return String(localized: "tool.error.rateLimited", defaultValue: "The tool is temporarily rate limited.")
            case .cancelled:
                return String(localized: "tool.error.cancelled", defaultValue: "The tool call was cancelled.")
            case .transient:
                return String(localized: "tool.error.transient", defaultValue: "The tool hit a temporary problem.")
            case .permanent:
                return String(localized: "tool.error.permanent", defaultValue: "The tool couldn't complete this request.")
            case .unknownTool:
                return String(localized: "tool.error.unknownTool", defaultValue: "This tool isn't available.")
            }
        }
    }

    /// The ``ToolCall/id`` this result corresponds to.
    public let callId: String

    /// The tool's output, serialised as a string.
    ///
    /// For structured data, JSON-encode it before assigning.
    public let content: String

    /// Failure classification, or `nil` on success.
    ///
    /// Use this to drive retry/abort decisions in the orchestration loop and
    /// to render friendlier error messages in UI. The legacy boolean
    /// ``isError`` flag is derived from this field.
    public let errorKind: ErrorKind?

    /// `true` when the tool execution failed.
    ///
    /// Computed from ``errorKind`` — `errorKind != nil` means the call failed.
    /// Backends that support error context (e.g. OpenAI) surface this flag
    /// so the model can reason about the failure and potentially retry.
    public var isError: Bool { errorKind != nil }

    /// Creates a tool result.
    ///
    /// - Parameters:
    ///   - callId: The ``ToolCall/id`` this result belongs to.
    ///   - content: The tool's output string.
    ///   - errorKind: Failure classification, or `nil` on success. Defaults to `nil`.
    public init(callId: String, content: String, errorKind: ErrorKind? = nil) {
        self.callId = callId
        self.content = content
        self.errorKind = errorKind
    }

    /// Legacy initializer retained for backwards compatibility.
    ///
    /// Maps `isError == true` to ``ErrorKind/permanent`` and `isError == false`
    /// to `nil`. New code should pass an explicit ``ErrorKind`` via the primary
    /// initializer so the failure class is preserved on the wire.
    @available(*, deprecated, renamed: "init(callId:content:errorKind:)")
    public init(callId: String, content: String, isError: Bool) {
        self.callId = callId
        self.content = content
        self.errorKind = isError ? .permanent : nil
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case callId, content, errorKind, isError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callId = try c.decode(String.self, forKey: .callId)
        content = try c.decode(String.self, forKey: .content)
        // errorKind is authoritative when present. Otherwise fall back to the
        // legacy `isError` boolean: true → .permanent, false → nil. This lets
        // pre-v4 persisted ToolResults decode into the new shape without loss.
        if let kind = try c.decodeIfPresent(ErrorKind.self, forKey: .errorKind) {
            errorKind = kind
        } else if let legacyIsError = try c.decodeIfPresent(Bool.self, forKey: .isError) {
            errorKind = legacyIsError ? .permanent : nil
        } else {
            errorKind = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(callId, forKey: .callId)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(errorKind, forKey: .errorKind)
        // `isError` is intentionally NOT encoded — it is derived from errorKind
        // and emitting it would put two sources of truth on the wire.
    }
}

// MARK: - ToolChoice

/// Controls how the backend selects which tool to call, if any.
///
/// Pass this via ``GenerationConfig/toolChoice`` alongside a non-empty
/// ``GenerationConfig/tools`` list.
public enum ToolChoice: Sendable, Codable, Equatable, Hashable {

    /// The backend decides whether to call a tool (default behaviour).
    case auto

    /// The backend must not call any tool; it must produce a text response.
    case none

    /// The backend must call at least one tool.
    case required

    /// The backend must call the named tool specifically.
    case tool(name: String)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decode(String.self, forKey: .type)
        switch type_ {
        case "auto":     self = .auto
        case "none":     self = .none
        case "required": self = .required
        case "tool":
            let name = try container.decode(String.self, forKey: .name)
            self = .tool(name: name)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown ToolChoice type '\(type_)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try container.encode("auto", forKey: .type)
        case .none:
            try container.encode("none", forKey: .type)
        case .required:
            try container.encode("required", forKey: .type)
        case .tool(let name):
            try container.encode("tool", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}
