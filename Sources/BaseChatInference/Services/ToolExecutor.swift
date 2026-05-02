import Foundation

// MARK: - ToolExecutor

/// A runtime-executable tool definition.
///
/// Conformers pair a ``ToolDefinition`` (the JSON-Schema contract the model
/// sees) with an `execute(arguments:)` hook that runs the tool and returns a
/// ``ToolResult``. Executors are stored in a ``ToolRegistry`` and dispatched
/// by the orchestration loop when the model emits a ``ToolCall``.
///
/// ## Arguments type
///
/// The protocol intentionally takes ``JSONSchemaValue`` — not a raw `String`
/// — so adapter layers (MCP bridges, AppIntents, macro-generated tools) can
/// hand a structured, already-parsed argument tree to the executor without
/// re-serialising through a string. ``ToolRegistry/dispatch(_:)`` handles the
/// `String`→`JSONSchemaValue` parse at the registry boundary.
///
/// ## Typed adapter
///
/// Most callers do not implement this protocol directly. Use
/// ``TypedToolExecutor`` to wrap a strongly-typed Swift handler — the adapter
/// handles JSON encode/decode on both sides so the handler signature stays
/// free of `JSONSchemaValue`.
///
/// ## Atomicity
///
/// `execute(arguments:)` is **atomic** from the orchestrator's point of view:
/// the registry observes exactly one outcome per call — either a fully-formed
/// ``ToolResult`` returned from the function, or a thrown error. There is no
/// partial-emission channel. Executors that perform streaming or multi-step
/// work (streaming file reads, subprocess pipes, streamed HTTP responses,
/// multi-RPC transactions) MUST buffer that work internally and only return a
/// single complete ``ToolResult`` once the work has succeeded.
///
/// When an executor throws mid-work, ``ToolRegistry/dispatch(_:)`` records a
/// ``ToolResult`` with ``ToolResult/ErrorKind/permanent`` and
/// `String(describing: error)` as the content. Any in-flight state the
/// executor had accumulated — bytes read, chunks processed, rows fetched — is
/// discarded and never flows into the transcript. The model sees the error
/// description, not the partial output.
///
/// The throw path is classified as ``ToolResult/ErrorKind/permanent``
/// (not ``ToolResult/ErrorKind/transient``) by design: an uncategorised
/// thrown `Error` is the "I don't know what went wrong" escape hatch, and
/// labelling it retry-safe would push agents into loops on permanent
/// failures (logic bugs, schema mismatches, auth denials) that no amount of
/// retrying will fix. Executors that *know* a failure is retriable must
/// return an explicit ``ToolResult/init(callId:content:errorKind:)`` with
/// ``ToolResult/ErrorKind/transient`` instead of throwing — same rule for
/// ``ToolResult/ErrorKind/timeout``, ``ToolResult/ErrorKind/rateLimited``,
/// ``ToolResult/ErrorKind/cancelled``, and the other specific kinds.
/// Throwing is the last-resort catch-all, not a retry signal.
///
/// Practical consequences:
///
/// - If your tool streams and you want to preserve what you got before
///   failing, aggregate into a local buffer and only throw after you have
///   decided to abandon that buffer. If the partial result is useful, return
///   a successful ``ToolResult`` whose ``ToolResult/content`` contains the
///   buffered prefix plus a description of why collection stopped, rather
///   than throwing.
/// - If the failure is transient (disk I/O hiccup, dropped connection,
///   rate-limit response), return
///   `ToolResult(callId: "", content: "...", errorKind: .transient)` rather
///   than throwing — this tells the orchestrator the call is safe to retry.
/// - Do not rely on side-effects (written files, DB rows, API calls) to
///   communicate partial progress to later turns — the orchestrator only
///   sees the returned ``ToolResult``.
/// - A future extension may add an explicit partial-content channel; until
///   then, this atomic request/response shape is the contract.
///
/// ## Cooperative cancellation
///
/// `execute(arguments:)` runs inside a `Task` owned by the orchestrator
/// (``ToolRegistry/dispatch(_:)`` is invoked from a child task in
/// `GenerationQueue`). When the user hits stop mid-generation, the
/// orchestrator calls `Task.cancel()` on its active generation task and the
/// cancellation propagates into this executor through structured concurrency.
///
/// Executors **must** cooperate with cancellation. Concretely:
///
/// - Use cancellation-aware async APIs. `Task.sleep(for:)`, `URLSession`'s
///   async overloads, and most Foundation async APIs already throw when the
///   surrounding task is cancelled.
/// - Long CPU-bound or non-cancellable work should poll
///   `Task.checkCancellation()` (or check `Task.isCancelled`) at sensible
///   yield points and throw `CancellationError` to bail out promptly.
/// - Bridged callback APIs (e.g. `URLSessionDataTask` via
///   `withTaskCancellationHandler`) must register an `onCancel:` closure
///   that calls the underlying `cancel()` so the in-flight request is torn
///   down. Otherwise the request leaks past the user's stop.
///
/// When the executor cooperates, ``ToolRegistry/dispatch(_:)`` synthesises
/// a ``ToolResult`` with ``ToolResult/ErrorKind/cancelled`` and the fixed
/// content `"cancelled by user"`. The orchestrator records it in the
/// transcript and **stops the dispatch loop** — no further backend turn
/// runs after a cancelled tool. Executors that fail to cooperate may
/// produce a real value before cancellation is observed; in that case the
/// registry still upgrades the outcome to
/// ``ToolResult/ErrorKind/cancelled`` because the contract is "no
/// post-stop tool output flows into the transcript" — but the executor
/// has wasted user-visible work and may have leaked resources (open file
/// handles, in-flight HTTP requests). Cooperate.
public protocol ToolExecutor: Sendable {

    /// The JSON-Schema contract exposed to the model and the ``ToolRegistry``
    /// lookup key. ``ToolDefinition/name`` must be unique within a registry
    /// (case-insensitive).
    var definition: ToolDefinition { get }

    /// Whether this executor is safe to dispatch concurrently with itself or
    /// with other tools in the same batch.
    ///
    /// Default `false` (sequential dispatch). Override `true` for stateless
    /// executors — HTTP fetches, pure computations, read-only filesystem.
    ///
    /// The agent-loop driver consults this flag when a generation round
    /// produces more than one ``ToolCall``: parallel dispatch via
    /// `withTaskGroup` is used only when *every* executor in the batch opts
    /// in. If any returns `false`, the driver falls back to sequential
    /// dispatch — preserving the registry's reentrancy contract for tools
    /// with shared state.
    var supportsConcurrentDispatch: Bool { get }

    /// Whether this tool needs explicit per-call user approval before the
    /// orchestrator dispatches it.
    ///
    /// Side-effecting tools (writes a file, sends a message, calls a paid
    /// API) should set this to `true` so a UI-layer ``ToolApprovalGate`` is
    /// consulted before execution. Pure-read tools should leave the default
    /// of `false` so they auto-approve regardless of the host's policy. The
    /// generation coordinator queries this flag via
    /// ``ToolRegistry/requiresApproval(toolName:)`` and skips the gate hop
    /// entirely when false — read-only tools never block on a user prompt.
    var requiresApproval: Bool { get }

    /// Executes the tool with already-parsed JSON arguments.
    ///
    /// The returned ``ToolResult/callId`` may be empty — ``ToolRegistry``
    /// stamps the correct id from the incoming ``ToolCall`` before returning
    /// the result to the caller. Thrown errors are caught by the registry and
    /// turned into ``ToolResult/ErrorKind/permanent`` results; to signal a
    /// retriable failure, return a ``ToolResult`` with an explicit
    /// ``ToolResult/ErrorKind/transient`` (or another specific kind) instead
    /// of throwing.
    ///
    /// This call is **atomic** — see the protocol-level ``ToolExecutor``
    /// documentation. Partial work accumulated before a throw is discarded
    /// by the orchestrator; aggregate internally and only throw once you
    /// have decided to abandon the buffer.
    func execute(arguments: JSONSchemaValue) async throws -> ToolResult
}

extension ToolExecutor {
    /// Default: read-only tool, no approval needed. Side-effecting tools
    /// override to `true`.
    public var requiresApproval: Bool { false }

    /// Default: sequential dispatch. Stateless executors should override
    /// to `true` to opt into parallel batch dispatch.
    public var supportsConcurrentDispatch: Bool { false }
}

// MARK: - TypedToolExecutor

/// Generic adapter that exposes a strongly-typed Swift handler as a
/// ``ToolExecutor``.
///
/// The adapter owns three responsibilities:
/// 1. Decode the incoming ``JSONSchemaValue`` into `Arguments` via `JSONDecoder`.
/// 2. Call the handler.
/// 3. Encode the handler's `Result` as a JSON string and wrap it in a ``ToolResult``.
///
/// ```swift
/// struct WeatherArgs: Decodable, Sendable { let city: String }
/// struct WeatherResult: Encodable, Sendable { let summary: String; let celsius: Double }
///
/// let weather = TypedToolExecutor<WeatherArgs, WeatherResult>(
///     definition: ToolDefinition(name: "get_weather", description: "Returns weather.", parameters: schema)
/// ) { args in
///     WeatherResult(summary: "Sunny", celsius: 22.0)
/// }
/// registry.register(weather)
/// ```
///
/// Decode or encode failures throw — ``ToolRegistry/dispatch(_:)`` catches them
/// and returns a ``ToolResult/ErrorKind/permanent`` result. Malformed JSON in
/// the raw ``ToolCall/arguments`` string is classified as
/// ``ToolResult/ErrorKind/invalidArguments`` at the registry boundary before
/// this adapter sees it.
///
/// ## Atomicity
///
/// The adapter is inherently atomic: the handler's `Result` is JSON-encoded
/// exactly once **after** the handler returns normally. If the handler throws,
/// nothing is encoded and no ``ToolResult`` is produced — the error bubbles to
/// ``ToolRegistry/dispatch(_:)`` which records a
/// ``ToolResult/ErrorKind/permanent`` result with the error description and
/// discards any work the handler had performed. See the ``ToolExecutor``
/// protocol's Atomicity section for the full contract; handlers that perform
/// streaming or multi-step work should buffer internally before returning.
public struct TypedToolExecutor<Arguments: Decodable & Sendable, Result: Encodable & Sendable>: ToolExecutor {

    public let definition: ToolDefinition

    public let requiresApproval: Bool

    private let handler: @Sendable (Arguments) async throws -> Result

    /// Creates a typed executor.
    ///
    /// - Parameters:
    ///   - definition: The tool contract exposed to the model. ``ToolDefinition/parameters``
    ///     should describe the JSON shape of `Arguments`.
    ///   - requiresApproval: When `true`, the orchestrator routes calls to
    ///     this tool through a ``ToolApprovalGate`` before execution. Defaults
    ///     to `false` (auto-approve, suitable for pure-read tools).
    ///   - handler: Runs the tool. Thrown errors become ``ToolResult/ErrorKind/permanent``
    ///     results at the registry layer.
    public init(
        definition: ToolDefinition,
        requiresApproval: Bool = false,
        handler: @Sendable @escaping (Arguments) async throws -> Result
    ) {
        self.definition = definition
        self.requiresApproval = requiresApproval
        self.handler = handler
    }

    public func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        // Route through Data so we don't need a bespoke bridge between
        // JSONSchemaValue and arbitrary Decodable types — Foundation already
        // handles the decode perfectly via the standard JSON path.
        let argsData = try JSONEncoder().encode(arguments)
        let decoded = try JSONDecoder().decode(Arguments.self, from: argsData)
        let result = try await handler(decoded)

        let resultData = try JSONEncoder().encode(result)
        // Prefer a UTF-8 string so the model receives readable JSON rather than
        // base64. JSON encoders always emit valid UTF-8, so the force is safe.
        let content = String(data: resultData, encoding: .utf8) ?? ""

        // callId is intentionally empty here — ToolRegistry.dispatch stamps the
        // correct id from the incoming ToolCall before returning to the caller.
        return ToolResult(callId: "", content: content, errorKind: nil)
    }
}
