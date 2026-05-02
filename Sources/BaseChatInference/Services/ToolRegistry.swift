import Foundation

// MARK: - JSONSchemaValidating (wave 2 hook)

/// Validates a parsed JSON argument payload against a ``JSONSchemaValue``
/// schema.
///
/// ``ToolRegistry`` depends on this protocol rather than the concrete
/// ``JSONSchemaValidator`` struct so tests can inject a stub and wave-2 wiring
/// can evolve without breaking ABI. The production conformer is
/// ``JSONSchemaValidator`` (see `JSONSchemaValidator.swift`); it returns the
/// richer ``JSONSchemaValidator/ValidationFailure`` internally and adapts it to
/// the `String?` shape here so the registry stays protocol-friendly.
public protocol JSONSchemaValidating: Sendable {

    /// Returns `nil` when `value` satisfies `schema`, or a human-readable
    /// error description when it does not.
    ///
    /// Named `validateAgainst(...)` rather than `validate(...)` so the
    /// protocol method does not collide with
    /// ``JSONSchemaValidator/validate(_:against:)-ValidationFailure`` at
    /// direct call sites that hold the concrete validator type. The registry
    /// always routes through this protocol method and sees a single
    /// unambiguous signature.
    func validateAgainst(_ schema: JSONSchemaValue, value: JSONSchemaValue) -> String?
}

// MARK: - ToolRegistry

/// Main-actor store of ``ToolExecutor`` instances keyed by case-insensitive
/// tool name.
///
/// The registry is the single dispatch seam between the generation loop and
/// user-registered tools. It handles:
///
/// - case-insensitive name lookup (with a warning when the model casing
///   differs from registration)
/// - JSON parsing of the raw ``ToolCall/arguments`` string into
///   ``JSONSchemaValue``
/// - optional schema validation (wave 2 wires an injected
///   ``JSONSchemaValidating`` implementation)
/// - stamping ``ToolResult/callId`` from the incoming call
/// - classifying lookup / parse / throw failures into
///   ``ToolResult/ErrorKind`` values
///
/// ## Isolation
///
/// ``ToolRegistry`` is deliberately `@MainActor final class`, not an `actor`.
/// The coordinator that drives it is MainActor-isolated; making the registry
/// an actor would force a hop on every dispatch for no benefit. The executor's
/// async `execute` call may still suspend off the main actor inside its own
/// implementation.
@MainActor public final class ToolRegistry {

    // MARK: Storage

    /// Keyed on the lowercased tool name for case-insensitive lookup.
    private var tools: [String: any ToolExecutor] = [:]

    // MARK: Configuration

    /// Optional validator used to check parsed arguments against
    /// ``ToolDefinition/parameters``.
    ///
    /// Wave 1 leaves this `nil` — dispatch skips validation. Wave 2 injects a
    /// concrete ``JSONSchemaValidator`` (or any other ``JSONSchemaValidating``
    /// conformer) so failures come back as ``ToolResult/ErrorKind/invalidArguments``.
    public var validator: (any JSONSchemaValidating)? = nil

    // MARK: - Init

    /// Creates a registry pre-populated with the supplied tools.
    ///
    /// Each tool is registered in order, so later entries override earlier
    /// ones on name collision (with the same override warning emitted from
    /// ``register(_:)``).
    ///
    /// ``validator`` defaults to `nil` on a freshly-constructed registry; the
    /// generation coordinator installs a default ``JSONSchemaValidator`` on
    /// first dispatch when one has not been wired explicitly. Tests that need
    /// the no-validator behaviour can keep using this initializer without
    /// opting out of the protocol.
    public init(tools: [any ToolExecutor] = []) {
        for tool in tools {
            register(tool)
        }
    }

    // MARK: - Registration

    /// Registers a tool, replacing any existing tool with the same name.
    ///
    /// Names are compared case-insensitively. Overrides log a warning so
    /// accidental collisions during ad-hoc tool wiring are visible in the
    /// inference log.
    public func register(_ tool: any ToolExecutor) {
        let key = tool.definition.name.lowercased()
        if tools[key] != nil {
            Log.inference.warning(
                "ToolRegistry: overriding existing tool '\(tool.definition.name, privacy: .public)'"
            )
        }
        tools[key] = tool
    }

    /// Removes a tool by name. No-op when the name is not registered.
    public func unregister(name: String) {
        tools.removeValue(forKey: name.lowercased())
    }

    /// Returns `true` when a tool is registered under `name` (case-insensitive).
    public func contains(name: String) -> Bool {
        tools[name.lowercased()] != nil
    }

    /// All registered tool definitions, sorted by name for stable diffs / tests.
    public var definitions: [ToolDefinition] {
        tools.values
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }

    /// Returns the registered executor's ``ToolExecutor/requiresApproval``
    /// flag, or `false` when no tool is registered under `toolName`.
    ///
    /// The generation coordinator queries this before invoking the
    /// ``ToolApprovalGate`` so read-only tools auto-approve without a UI hop.
    /// Unknown names return `false` because dispatch will synthesise an
    /// `unknownTool` error result anyway — there is nothing for the user to
    /// approve.
    public func requiresApproval(toolName: String) -> Bool {
        tools[toolName.lowercased()]?.requiresApproval ?? false
    }

    // MARK: - Dispatch

    /// Resolves `call.toolName` to an executor, parses its arguments, runs
    /// the tool, and returns a stamped ``ToolResult``.
    ///
    /// Dispatch classifies failures as follows:
    /// - Unknown tool → ``ToolResult/ErrorKind/unknownTool``
    /// - Malformed argument JSON → ``ToolResult/ErrorKind/invalidArguments``
    /// - Schema validation failure (when ``validator`` is set) →
    ///   ``ToolResult/ErrorKind/invalidArguments``
    /// - Executor throws → ``ToolResult/ErrorKind/permanent`` with
    ///   `String(describing: error)` as the content
    ///
    /// The returned ``ToolResult/callId`` always matches the incoming
    /// ``ToolCall/id``, regardless of what the executor returned.
    public func dispatch(_ call: ToolCall) async -> ToolResult {
        // 1. Case-insensitive lookup with a mismatch warning.
        let key = call.toolName.lowercased()
        guard let executor = tools[key] else {
            return ToolResult(
                callId: call.id,
                content: "Unknown tool '\(call.toolName)'",
                errorKind: .unknownTool
            )
        }
        if executor.definition.name != call.toolName {
            Log.inference.warning(
                "ToolRegistry: case-insensitive match for '\(call.toolName, privacy: .public)' (registered as '\(executor.definition.name, privacy: .public)')"
            )
        }

        // 2. Parse the raw argument JSON.
        let parsedArguments: JSONSchemaValue
        if call.arguments.isEmpty {
            // Empty string is a common "no arguments" signal from backends
            // that don't emit `{}` — treat it as an empty object rather than
            // failing the call before it reaches the executor.
            parsedArguments = .object([:])
        } else {
            guard let data = call.arguments.data(using: .utf8) else {
                return ToolResult(
                    callId: call.id,
                    content: "arguments are not valid JSON: non-UTF8 payload",
                    errorKind: .invalidArguments
                )
            }
            do {
                parsedArguments = try JSONDecoder().decode(JSONSchemaValue.self, from: data)
            } catch {
                return ToolResult(
                    callId: call.id,
                    content: "arguments are not valid JSON: \(error)",
                    errorKind: .invalidArguments
                )
            }
        }

        // 3. Optional schema validation (wave 2 wiring).
        if let validator,
           let message = validator.validateAgainst(executor.definition.parameters, value: parsedArguments) {
            return ToolResult(
                callId: call.id,
                content: "arguments failed schema validation: \(message)",
                errorKind: .invalidArguments
            )
        }

        // 4. Execute and stamp callId.
        do {
            let raw = try await executor.execute(arguments: parsedArguments)
            return ToolResult(
                callId: call.id,
                content: raw.content,
                errorKind: raw.errorKind
            )
        } catch {
            return ToolResult(
                callId: call.id,
                content: String(describing: error),
                errorKind: .permanent
            )
        }
    }
}
