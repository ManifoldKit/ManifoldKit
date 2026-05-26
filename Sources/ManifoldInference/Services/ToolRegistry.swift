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
///
/// ## Reentrancy
///
/// MainActor isolation serialises *entry* into ``register(_:)``,
/// ``unregister(name:)``, and ``dispatch(_:)``, but `await
/// executor.execute(arguments:)` inside ``dispatch(_:)`` suspends the
/// current task. While that suspension is in flight, another MainActor
/// caller can enter the registry and mutate the tool table — register
/// a replacement, unregister the in-flight tool, swap the validator, or
/// adjust the ``outputPolicy``.
///
/// The dispatch contract is:
///
/// > ``ToolRegistry`` captures the executor at dispatch entry. Registry
/// > mutations during a suspended dispatch do not affect that dispatch's
/// > outcome — the originally-resolved executor runs to completion.
/// > Subsequent dispatches see the mutated state.
///
/// Concretely:
///
/// - The executor is looked up exactly once, at the top of ``dispatch(_:)``.
///   The local `executor` reference holds the value; later table mutations
///   on the same name do not retarget it.
/// - The ``outputPolicy`` and ``validator`` references are also captured
///   into local constants at dispatch entry, so a mid-flight policy swap
///   only affects subsequent dispatches.
/// - Snapshots taken from ``definitions`` reflect whatever state the
///   table is in when the snapshot is read. Mid-dispatch mutations are
///   visible immediately — the registry doesn't hide the change, it
///   merely refuses to retarget the in-flight call.
///
/// As an observability hook, ``unregister(name:)`` emits a warning when
/// it drops a tool that has at least one dispatch in flight. The
/// in-flight dispatch still completes against the originally-resolved
/// executor; the warning exists so ad-hoc registry juggling is visible
/// in the inference log.
@MainActor public final class ToolRegistry {
    private static let reservedToolPrefixes = ["mcp__", "intent__"]

    // MARK: Storage

    /// Keyed on the lowercased tool name for case-insensitive lookup.
    private var tools: [String: any ToolExecutor] = [:]

    /// In-flight dispatch counter, keyed on the lowercased tool name.
    ///
    /// Incremented at the top of ``dispatch(_:)`` once the executor has
    /// been resolved, decremented in `defer`. ``unregister(name:)``
    /// reads this to decide whether to log the
    /// "unregistering while dispatch is in flight" warning. The counter
    /// is single-threaded — every mutator hops the MainActor first.
    private var dispatchesInFlight: [String: Int] = [:]

    // MARK: Configuration

    /// Optional validator used to check parsed arguments against
    /// ``ToolDefinition/parameters``.
    ///
    /// Wave 1 leaves this `nil` — dispatch skips validation. Wave 2 injects a
    /// concrete ``JSONSchemaValidator`` (or any other ``JSONSchemaValidating``
    /// conformer) so failures come back as ``ToolResult/ErrorKind/invalidArguments``.
    public var validator: (any JSONSchemaValidating)? = nil

    /// When `true`, top-level string arguments are coerced to the primitive
    /// type declared in the tool's `properties` schema before validation —
    /// **and the coerced value is what the executor receives**.
    ///
    /// Smaller open-weight models routinely emit `"42"` for an `integer`
    /// property or `"true"` for a `boolean`. Without coercion, the schema
    /// validator rejects these calls and the user sees a hard failure for a
    /// pure serialisation quirk. See ``ToolArgumentCoercer`` for the exact
    /// rules — coercion only runs at the top level and unparseable strings
    /// fall through unchanged so genuine type errors still surface.
    ///
    /// Tools that want to inspect the raw model output themselves can opt
    /// out by setting this to `false`.
    public var coercesArguments: Bool = true

    /// Size policy applied to tool results before they are returned from
    /// ``dispatch(_:)``.
    ///
    /// Defaults to ``ToolOutputPolicy``'s default — 32 KB
    /// (``OversizeAction/rejectWithError``). See ``ToolOutputPolicy`` for
    /// guidance on when to raise the ceiling (long file reads on
    /// large-context backends) versus keep the default.
    ///
    /// The policy is captured into a local constant at dispatch entry, so
    /// changing it mid-dispatch only affects subsequent dispatches —
    /// matching the reentrancy contract on the registry itself.
    public var outputPolicy: ToolOutputPolicy = ToolOutputPolicy()

    /// Optional allow-list for tools that should be advertised to the active
    /// backend. Dispatch remains available for every registered tool; this
    /// only narrows the definitions passed in `GenerationConfig.tools`.
    public var advertisedToolNames: Set<String>? {
        get { advertisedToolNameKeys }
        set { advertisedToolNameKeys = newValue.map { Set($0.map { $0.lowercased() }) } }
    }

    private var advertisedToolNameKeys: Set<String>?

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
        if Self.reservedToolPrefixes.contains(where: { key.hasPrefix($0) }) {
            Log.inference.warning(
                "ToolRegistry: refusing to register reserved tool prefix for '\(tool.definition.name, privacy: .public)'"
            )
            return
        }
        if tools[key] != nil {
            Log.inference.warning(
                "ToolRegistry: overriding existing tool '\(tool.definition.name, privacy: .public)'"
            )
        }
        tools[key] = tool
    }

    /// Removes a tool by name. No-op when the name is not registered.
    ///
    /// When the named tool has at least one in-flight dispatch, this method
    /// logs an observability warning before removing the entry. The
    /// in-flight dispatch still completes against the executor that was
    /// resolved at its entry point — see the type-level "Reentrancy"
    /// section.
    public func unregister(name: String) {
        let key = name.lowercased()
        if let inFlight = dispatchesInFlight[key], inFlight > 0 {
            Log.inference.warning(
                "ToolRegistry: unregistering '\(name, privacy: .public)' while a dispatch for that tool is in flight; the in-flight dispatch will complete with the originally-resolved executor"
            )
        }
        tools.removeValue(forKey: key)
    }

    /// Returns `true` when a tool is registered under `name` (case-insensitive).
    public func contains(name: String) -> Bool {
        tools[name.lowercased()] != nil
    }

    /// All registered tool definitions, sorted by name for stable diffs / tests.
    ///
    /// Pass the result as `GenerationConfig.tools` when enqueueing a request.
    /// For local backends (3B–8B instruct models), keep this list at or below
    /// 5 entries — see README "Tool Calling" section.
    public var definitions: [ToolDefinition] {
        let result = sortedDefinitions()
        #if DEBUG
        if result.count > 5 {
            print("[ManifoldKit] ⚠️ \(result.count) tools in this request. Local backends (3B–8B) degrade beyond ~5 — see README Tool Calling section.")
        }
        #endif
        return result
    }

    /// Registered tool definitions after applying ``advertisedToolNames``.
    ///
    /// Use this for model-facing `GenerationConfig.tools` when a host needs to
    /// hide a subset for a backend-specific policy while keeping dispatch
    /// available for in-flight or previously-advertised calls.
    public var advertisedDefinitions: [ToolDefinition] {
        let allDefinitions = sortedDefinitions()
        let result = advertisedToolNameKeys.map { keys in
            allDefinitions.filter { keys.contains($0.name.lowercased()) }
        } ?? allDefinitions
        #if DEBUG
        if result.count > 5 {
            print("[ManifoldKit] ⚠️ \(result.count) tools in this request. Local backends (3B–8B) degrade beyond ~5 — see README Tool Calling section.")
        }
        #endif
        return result
    }

    private func sortedDefinitions() -> [ToolDefinition] {
        tools.values
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }

    /// Returns the registered executor for `toolName` (case-insensitive),
    /// or `nil` when no tool is registered under that name.
    ///
    /// Used by agent-loop drivers to read
    /// ``ToolExecutor/supportsConcurrentDispatch`` on every executor in a
    /// batch before deciding whether to dispatch the batch in parallel.
    /// The lookup does not mutate the registry and does not increment the
    /// in-flight counter.
    public func executor(for toolName: String) -> (any ToolExecutor)? {
        tools[toolName.lowercased()]
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
    /// - Executor throws `CancellationError`, or the surrounding task is
    ///   cancelled mid-execute →
    ///   ``ToolResult/ErrorKind/cancelled`` with a fixed
    ///   `"cancelled by user"` content. This is the cooperative-cancellation
    ///   path the orchestrator relies on when the user hits stop while a
    ///   tool is in flight; see ``ToolExecutor`` for the executor-author
    ///   contract.
    /// - Executor throws any other error → ``ToolResult/ErrorKind/permanent``
    ///   with `String(describing: error)` as the content.
    ///
    /// The returned ``ToolResult/callId`` always matches the incoming
    /// ``ToolCall/id``, regardless of what the executor returned.
    public func dispatch(_ call: ToolCall) async -> ToolResult {
        var terminalResult: ToolResult?
        for await event in dispatchStreaming(call) {
            if case .completed(let result) = event {
                terminalResult = result
                break
            }
        }
        if Task.isCancelled {
            return Self.cancelledResult(callId: call.id)
        }
        return terminalResult ?? ToolResult(
            callId: call.id,
            content: "tool stream finished without a terminal result",
            errorKind: .permanent
        )
    }

    /// Streaming variant of ``dispatch(_:)``.
    ///
    /// Emits any executor-provided ``ToolExecutionEvent/progress(message:fraction:)``
    /// chunks, then exactly one stamped ``ToolExecutionEvent/completed(_:)``.
    /// Lookup, argument, schema, cancellation, and thrown-error failures are
    /// still converted into terminal ``ToolResult`` values with the same
    /// classification as ``dispatch(_:)``.
    public func dispatchStreaming(_ call: ToolCall) -> AsyncStream<ToolExecutionEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                await self.performStreamingDispatch(call, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performStreamingDispatch(
        _ call: ToolCall,
        continuation: AsyncStream<ToolExecutionEvent>.Continuation
    ) async {
        func complete(_ result: ToolResult) {
            continuation.yield(.completed(result))
            continuation.finish()
        }

        // 1. Case-insensitive lookup with a mismatch warning.
        let key = call.toolName.lowercased()
        guard let executor = tools[key] else {
            complete(ToolResult(
                callId: call.id,
                content: "Unknown tool '\(call.toolName)'",
                errorKind: .unknownTool
            ))
            return
        }
        if executor.definition.name != call.toolName {
            Log.inference.warning(
                "ToolRegistry: case-insensitive match for '\(call.toolName, privacy: .public)' (registered as '\(executor.definition.name, privacy: .public)')"
            )
        }

        // Capture mutable configuration into local constants so a mid-flight
        // mutation of `outputPolicy`/`validator` does not retarget this
        // dispatch. See the type-level "Reentrancy" section.
        let policy = outputPolicy
        let activeValidator = validator
        let shouldCoerceArguments = coercesArguments

        // Track this dispatch as in-flight so unregister(name:) can emit an
        // observability warning if the registry is mutated mid-dispatch.
        dispatchesInFlight[key, default: 0] += 1
        defer {
            let remaining = (dispatchesInFlight[key] ?? 1) - 1
            if remaining <= 0 {
                dispatchesInFlight.removeValue(forKey: key)
            } else {
                dispatchesInFlight[key] = remaining
            }
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
                complete(ToolResult(
                    callId: call.id,
                    content: "arguments are not valid JSON: non-UTF8 payload",
                    errorKind: .invalidArguments
                ))
                return
            }
            do {
                parsedArguments = try JSONDecoder().decode(JSONSchemaValue.self, from: data)
            } catch {
                complete(ToolResult(
                    callId: call.id,
                    content: "arguments are not valid JSON: \(error)",
                    errorKind: .invalidArguments
                ))
                return
            }
        }

        // 3. Optional argument coercion — runs before validation so a
        // string "42" for an integer property reaches the validator as
        // .number(42), not .string("42"). The coerced value is then passed
        // through to the executor as well: the whole point of coercion is
        // that small models emit `"42"` and the tool wants `42`, so the
        // executor must see the coerced form. Tools that need the raw
        // string can opt out by clearing ``coercesArguments``.
        //
        // `coerceBestEffort` swallows ``ToolArgumentError/schemaTooDeep``:
        // a pathologically deep schema falls through to the validator with
        // un-coerced args, which then surfaces whatever real error the
        // schema produces. We don't want a depth cap to short-circuit
        // dispatch on a schema the validator might still accept.
        let dispatchArguments: JSONSchemaValue
        if shouldCoerceArguments {
            dispatchArguments = ToolArgumentCoercer.coerceBestEffort(parsedArguments, against: executor.definition.parameters)
        } else {
            dispatchArguments = parsedArguments
        }

        // 4. Optional schema validation (wave 2 wiring).
        if let activeValidator,
           let message = activeValidator.validateAgainst(executor.definition.parameters, value: dispatchArguments) {
            complete(ToolResult(
                callId: call.id,
                content: "arguments failed schema validation: \(message)",
                errorKind: .invalidArguments
            ))
            return
        }

        // 5. Execute, stamp callId, and apply the size policy.
        var sawTerminalResult = false
        do {
            for try await event in executor.executeStreaming(arguments: dispatchArguments) {
                if Task.isCancelled {
                    complete(Self.cancelledResult(callId: call.id))
                    return
                }

                switch event {
                case .progress(let message, let fraction):
                    continuation.yield(.progress(message: message, fraction: fraction))

                case .completed(let raw):
                    sawTerminalResult = true
                    if Task.isCancelled {
                        complete(Self.cancelledResult(callId: call.id))
                        return
                    }
                    let outcome = ToolResult(
                        callId: call.id,
                        content: raw.content,
                        errorKind: raw.errorKind
                    )
                    complete(Self.applyOutputPolicy(policy, to: outcome))
                    return
                }
            }

            if !sawTerminalResult {
                complete(ToolResult(
                    callId: call.id,
                    content: "tool stream finished without a terminal result",
                    errorKind: .permanent
                ))
            }
        } catch is CancellationError {
            complete(Self.cancelledResult(callId: call.id))
        } catch {
            // Foundation APIs that observe cancellation often throw
            // `URLError(.cancelled)` rather than `CancellationError`. When
            // the surrounding task has been cancelled, classify any thrown
            // error as a cooperative cancellation so the dispatcher can
            // distinguish "user hit stop" from a true permanent failure.
            if Task.isCancelled {
                complete(Self.cancelledResult(callId: call.id))
                return
            }
            complete(ToolResult(
                callId: call.id,
                content: String(describing: error),
                errorKind: .permanent
            ))
        }
    }

    // MARK: - Output policy

    private static func cancelledResult(callId: String) -> ToolResult {
        ToolResult(
            callId: callId,
            content: "cancelled by user",
            errorKind: .cancelled
        )
    }

    /// Applies ``outputPolicy`` to a finalized ``ToolResult``.
    ///
    /// Behaviour:
    ///
    /// - Successful results that fit within ``ToolOutputPolicy/maxBytes``
    ///   pass through unchanged.
    /// - Successful results that exceed the ceiling are rejected,
    ///   truncated, or allowed according to ``ToolOutputPolicy/onOversize``.
    /// - Already-errored results bypass the ``OversizeAction`` switch:
    ///   re-classifying a `.permanent` error as `.invalidArguments` would
    ///   confuse the model's retry logic, so oversize error content is
    ///   simply truncated to ``ToolOutputPolicy/maxBytes`` while
    ///   preserving the original ``ToolResult/errorKind``. Error messages
    ///   that overflow the budget are pathological enough that the
    ///   trimmed payload is always more useful than a hard reject.
    /// - ``OversizeAction/allow`` skips the ceiling only for non-errored
    ///   oversize results; already-errored results are still trimmed as
    ///   described above (debug only).
    static func applyOutputPolicy(
        _ policy: ToolOutputPolicy,
        to result: ToolResult
    ) -> ToolResult {
        let byteLength = result.content.utf8.count
        if byteLength <= policy.maxBytes {
            return result
        }

        // Already-errored results: keep the original errorKind, just trim.
        if result.errorKind != nil {
            return ToolResult(
                callId: result.callId,
                content: truncateUTF8(result.content, toByteLimit: policy.maxBytes),
                errorKind: result.errorKind
            )
        }

        switch policy.onOversize {
        case .allow:
            return result

        case .rejectWithError:
            return ToolResult(
                callId: result.callId,
                content: "output exceeds maxBytes (\(byteLength) > \(policy.maxBytes))",
                errorKind: .invalidArguments
            )

        case .truncate(let suffix):
            return truncateOversize(result: result, byteLength: byteLength, maxBytes: policy.maxBytes, suffix: suffix)

        case .spillToFile(let threshold, let message):
            // Below threshold: still oversize per maxBytes, but small
            // enough that a file round-trip is unwarranted. Fall back to
            // a generic truncation rather than silently passing through.
            if byteLength < threshold {
                return truncateOversize(result: result, byteLength: byteLength, maxBytes: policy.maxBytes, suffix: "... [truncated]")
            }
            do {
                let url = try ToolSpillReaper.spill(content: result.content)
                return ToolResult(
                    callId: result.callId,
                    content: message(byteLength, url),
                    errorKind: nil
                )
            } catch {
                // IO failure during spill must not crash the chat loop.
                // Degrade gracefully to truncation so the model still gets
                // a partial answer it can act on.
                Log.inference.warning(
                    "tool-spill write failed (\(String(describing: error), privacy: .public)); falling back to truncation"
                )
                return truncateOversize(result: result, byteLength: byteLength, maxBytes: policy.maxBytes, suffix: "... [truncated; spill failed]")
            }
        }
    }

    /// Shared truncation helper used by both ``OversizeAction/truncate`` and
    /// the ``OversizeAction/spillToFile`` fallback paths. Guarantees the
    /// returned content's UTF-8 byte length is `<= maxBytes`.
    private static func truncateOversize(
        result: ToolResult,
        byteLength: Int,
        maxBytes: Int,
        suffix: String
    ) -> ToolResult {
        let suffixBytes = suffix.utf8.count
        if suffixBytes >= maxBytes {
            return ToolResult(
                callId: result.callId,
                content: truncateUTF8(suffix, toByteLimit: maxBytes),
                errorKind: nil
            )
        }
        let bodyBudget = maxBytes - suffixBytes
        let trimmed = truncateUTF8(result.content, toByteLimit: bodyBudget)
        return ToolResult(
            callId: result.callId,
            content: trimmed + suffix,
            errorKind: nil
        )
    }

    /// Trims `string` so its UTF-8 byte length is `<= byteLimit` without
    /// splitting a multi-byte codepoint.
    ///
    /// Walks back from the limit until we find a byte that begins a UTF-8
    /// scalar (i.e. is not a continuation byte `0b10xxxxxx`). Cheap and
    /// boundary-safe for any Swift `String`.
    static func truncateUTF8(_ string: String, toByteLimit byteLimit: Int) -> String {
        if byteLimit <= 0 { return "" }
        let utf8 = string.utf8
        if utf8.count <= byteLimit { return string }

        var endIndex = utf8.index(utf8.startIndex, offsetBy: byteLimit)
        // Walk back past continuation bytes (10xxxxxx) so we don't slice
        // mid-codepoint. The leading byte of any valid UTF-8 scalar has
        // top bits 0xxxxxxx, 110xxxxx, 1110xxxx, or 11110xxx — never
        // 10xxxxxx.
        while endIndex > utf8.startIndex {
            let byte = utf8[utf8.index(before: endIndex)]
            if (byte & 0b1100_0000) == 0b1000_0000 {
                endIndex = utf8.index(before: endIndex)
            } else {
                // The byte before endIndex is a leading byte. We need to
                // confirm the scalar starting there fits entirely within
                // the limit; if not, drop it.
                let leadingIndex = utf8.index(before: endIndex)
                let leading = utf8[leadingIndex]
                let scalarLength: Int
                if leading & 0b1000_0000 == 0 {
                    scalarLength = 1
                } else if leading & 0b1110_0000 == 0b1100_0000 {
                    scalarLength = 2
                } else if leading & 0b1111_0000 == 0b1110_0000 {
                    scalarLength = 3
                } else if leading & 0b1111_1000 == 0b1111_0000 {
                    scalarLength = 4
                } else {
                    // Malformed leading byte — treat as 1 to make progress.
                    scalarLength = 1
                }
                let scalarEnd = utf8.index(leadingIndex, offsetBy: scalarLength)
                if scalarEnd <= endIndex {
                    endIndex = scalarEnd
                } else {
                    endIndex = leadingIndex
                }
                break
            }
        }
        return String(decoding: utf8[utf8.startIndex..<endIndex], as: UTF8.self)
    }
}
