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
    /// A whole-number JSON value preserved as `Int64`.
    ///
    /// Whole-number JSON literals (e.g. `42`) decode to this case so that
    /// `int64` magnitudes above 2^53 survive an encode → decode round-trip
    /// without the precision loss they would suffer going through `Double`.
    case integer(Int64)
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
        } else if let i = try? container.decode(Int64.self) {
            // Whole-number literals decode here BEFORE Double so int64 values
            // above 2^53 keep full precision. Fractional literals (e.g. 4.2)
            // fail Int64 decode and fall through to the Double case below.
            self = .integer(i)
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
        case .integer(let i):
            try container.encode(i)
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

// MARK: - ToolResultPart

/// A typed content part carried by ``ToolResult/structuredContent``.
///
/// ## v1 vocabulary
///
/// The only case today is ``text(_:)``, which mirrors the existing string
/// carried by ``ToolResult/content``. Future 1.x releases will add cases such
/// as `image(data:mimeType:)` and `json(_:)` without breaking the existing
/// wire format, because this enum is decoded with tolerance for unknown types.
///
/// ## Vocabulary growth (1.x)
///
/// New cases will be added in minor releases. Consumers **must** handle
/// ``unknown(type:)`` — either by ignoring it or by forwarding the raw `type`
/// string to the host for logging. When switching over this enum in your code,
/// always include a `default:` branch or an explicit `case .unknown:` arm so
/// your app does not need to be updated every time a new part type ships.
///
/// ## Decode tolerance
///
/// Payloads carrying a `type` value that is not yet known to this SDK are
/// decoded into ``unknown(type:)`` rather than throwing, keeping old readers
/// forward-compatible with payloads produced by newer tool executors.
public enum ToolResultPart: Sendable, Codable, Equatable, Hashable {

    /// A plain-text content part. The `text` value is the literal string the
    /// tool produced — equivalent to ``ToolResult/content`` for text-only tools.
    case text(String)

    /// A part whose `type` discriminator is not recognised by this SDK version.
    ///
    /// The raw `type` string is preserved so callers can log or forward it.
    /// The payload beyond the `type` field is not decoded and is silently
    /// discarded — this is the intentional trust-boundary optional-decode
    /// exception: we prefer decode-to-unknown over a thrown error that would
    /// break forward compatibility.
    case unknown(type: String)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeString = try container.decode(String.self, forKey: .type)
        switch typeString {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        default:
            // Forward-compatible: unknown part types are preserved, not thrown.
            self = .unknown(type: typeString)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .unknown(let typeString):
            try container.encode(typeString, forKey: .type)
        }
    }
}

// MARK: - ToolResult

/// The outcome of executing a ``ToolCall``.
///
/// Feed this back to the backend (e.g. as an additional message in the
/// conversation history) so the model can incorporate the tool output
/// into its final response.
///
/// ## Dialog channel
///
/// ``dialog`` is an optional sidecar string carrying human-facing speech or
/// display text — typically populated by tool executors bridging AppIntents
/// that adopt `ProvidesDialog`. It is orthogonal to ``content``: ``content``
/// is the structured payload the model reads, while ``dialog`` is what the
/// host UI can speak or render verbatim to the user. Tools that don't
/// produce a separate dialog leave the field `nil`, and the on-wire JSON
/// omits the key entirely so existing consumers see no shape change.
///
/// ## Structured content sidecar
///
/// ``structuredContent`` is an optional typed payload that future 1.x releases
/// will use to carry multimodal or richly-typed tool output (images, JSON
/// objects, citations, etc.). In v1 it is always `nil` at runtime — the
/// canonical model-facing value remains ``content``. When non-`nil`, the array
/// is encoded on the wire; when `nil` the key is absent, keeping the wire
/// shape identical to pre-sidecar payloads for all existing producers and
/// consumers.
///
/// See ``ToolResultPart`` for the part vocabulary and its forward-compatibility
/// contract (new cases land as minor releases; consumers must handle
/// ``ToolResultPart/unknown(type:)``).
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
        /// A wire value not recognised by this SDK version.
        ///
        /// Forward-compatibility escape hatch: an `errorKind` raw string produced
        /// by a newer producer that this build doesn't know decodes here instead
        /// of throwing the whole ``ToolResult`` decode. The raw value `"unknown"`
        /// is stable; the original unrecognised string is not preserved.
        case unknown

        /// Forward-compatible tolerant decode.
        ///
        /// Unrecognised raw strings map to ``unknown`` rather than throwing, so a
        /// newer producer's `errorKind` vocabulary never breaks an older reader's
        /// ``ToolResult`` decode. `encode`/``rawValue`` stay synthesized.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ErrorKind(rawValue: raw) ?? .unknown
        }

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
            case .unknown:
                return String(localized: "tool.error.unknown", defaultValue: "The tool reported an unrecognized error.")
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

    /// Human-facing speech/display text produced by the tool, or `nil` when
    /// the tool doesn't emit a dialog channel.
    ///
    /// Orthogonal to ``content``: ``content`` is the structured payload the
    /// model reads (typically JSON), while ``dialog`` is the renderable
    /// string a host UI can speak or display verbatim. The canonical source
    /// is an AppIntent that adopts `ProvidesDialog` — the executor extracts
    /// the dialog string into this field and routes the structured value
    /// (from `ReturnsValue<T>`, when present) into ``content``.
    ///
    /// The field is encoded with `encodeIfPresent`, so the JSON for a
    /// non-dialog tool result is shape-identical to the pre-dialog wire
    /// format.
    public let dialog: String?

    /// Forward-compatible typed content parts, or `nil` for v1 string-only tools.
    ///
    /// This sidecar locks a shape before the 1.0 freeze so that 1.x releases
    /// can carry multimodal or richly-typed tool output (images, JSON objects,
    /// citations) without a breaking wire-format change.
    ///
    /// **v1 behaviour:** always `nil` at runtime. The model-facing canonical
    /// value remains ``content`` — backends read that string today and will
    /// continue to do so until a future release activates the typed path.
    ///
    /// **Forward compatibility:** when non-`nil`, the array is encoded under
    /// `"structuredContent"`. When `nil` the key is absent entirely, so
    /// existing producers and consumers see no wire-shape change. Old decoders
    /// that don't know this key will silently ignore it, and new decoders
    /// receiving a payload without it will decode `nil` — both directions are
    /// safe.
    ///
    /// See ``ToolResultPart`` for the part vocabulary and the
    /// ``ToolResultPart/unknown(type:)`` forward-compatibility contract.
    public let structuredContent: [ToolResultPart]?

    /// Creates a tool result.
    ///
    /// - Parameters:
    ///   - callId: The ``ToolCall/id`` this result belongs to.
    ///   - content: The tool's output string (model-facing canonical value).
    ///   - errorKind: Failure classification, or `nil` on success. Defaults to `nil`.
    ///   - dialog: Optional human-facing speech/display text, e.g. the
    ///     resolved string from an AppIntent's `ProvidesDialog` channel.
    ///     Defaults to `nil`.
    ///   - structuredContent: Optional typed content parts for forward-compatible
    ///     multimodal output. Defaults to `nil` (v1 behaviour: string-only).
    public init(
        callId: String,
        content: String,
        errorKind: ErrorKind? = nil,
        dialog: String? = nil,
        structuredContent: [ToolResultPart]? = nil
    ) {
        self.callId = callId
        self.content = content
        self.errorKind = errorKind
        self.dialog = dialog
        self.structuredContent = structuredContent
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case callId, content, errorKind, isError, dialog, structuredContent
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
        dialog = try c.decodeIfPresent(String.self, forKey: .dialog)
        structuredContent = try c.decodeIfPresent([ToolResultPart].self, forKey: .structuredContent)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(callId, forKey: .callId)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(errorKind, forKey: .errorKind)
        // `isError` is intentionally NOT encoded — it is derived from errorKind
        // and emitting it would put two sources of truth on the wire.
        // `dialog` uses encodeIfPresent so non-dialog tools emit the exact
        // pre-dialog JSON shape (no `"dialog"` key at all).
        try c.encodeIfPresent(dialog, forKey: .dialog)
        // `structuredContent` uses encodeIfPresent so v1 string-only results
        // emit no extra key, keeping the wire shape backward-compatible.
        try c.encodeIfPresent(structuredContent, forKey: .structuredContent)
    }
}

// MARK: - ToolExecutionEvent

/// One element of a ``ToolExecutor/executeStreaming(arguments:)`` stream.
///
/// Streaming-aware executors yield zero or more ``progress(message:fraction:)``
/// chunks for long-running work (downloads, multi-step queries, paginated
/// fetches), then yield exactly one terminal ``completed(_:)`` carrying the
/// same ``ToolResult`` a non-streaming `execute(arguments:)` would return.
///
/// ## Contract
///
/// - **Order**: any number of `.progress` events, followed by exactly one
///   `.completed`. `.completed` is always last; nothing follows it.
/// - **Cardinality**: `.completed` appears exactly once per successful stream.
///   On thrown errors the stream finishes with an error and no `.completed`
///   is yielded — mirror the single-shot `execute` contract.
/// - **Sendability**: ``ToolResult`` is `Sendable`, so this enum is `Sendable`
///   and safe to ferry across actor boundaries inside an `AsyncThrowingStream`.
///
/// ``ToolResult/ErrorKind`` is unchanged — streaming is additive on top of the
/// existing single-shot vocabulary, not a new failure mode.
public enum ToolExecutionEvent: Sendable {

    /// Interim progress chunk.
    ///
    /// - Parameters:
    ///   - message: Human-readable status (e.g. `"Fetched 12 of 47 records"`).
    ///   - fraction: Optional 0.0...1.0 completion fraction. `nil` when the
    ///     work has no known total (open-ended streams, single-step queries
    ///     that just want to ping liveness).
    case progress(message: String, fraction: Double?)

    /// Terminal value. Always exactly one per stream, always last.
    case completed(ToolResult)
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
