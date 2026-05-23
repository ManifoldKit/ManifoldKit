import Foundation
import ManifoldInference

#if canImport(AppIntents)
import AppIntents
#endif

#if canImport(AppIntents)

// MARK: - AppEntityResolver

/// Resolves an `AppEntity` identifier into a concrete instance.
///
/// Hosts inject a resolver when they expose AppIntents whose parameters are
/// `AppEntity`-typed. The default resolver, ``DefaultAppEntityResolver``,
/// dispatches to `EntityType.defaultQuery.entities(for: [id])` which is the
/// canonical AppIntents lookup path; bespoke hosts (caches, mocks, tests) can
/// supply their own conformance.
///
/// ## Why this exists
///
/// `AppEntity` is not generally `Decodable` — the framework loads entities via
/// `EntityQuery` rather than from JSON. The executor uses the resolver to
/// translate the model's `{ "id": "<value>" }` argument payload into a real
/// instance before handing the rest of the JSON to `JSONDecoder`. Resolved
/// entities arrive at the host intent's `init(from:)` via the decoder's
/// `userInfo` keyed by ``CodingUserInfoKey/manifoldResolvedEntities``.
@available(iOS 26, macOS 26, *)
public protocol AppEntityResolver: Sendable {
    /// Resolves a single id into an entity, or `nil` when no entity with that
    /// id exists. Throwing surfaces as ``ToolResult/ErrorKind/permanent``
    /// (or ``ToolResult/ErrorKind/permissionDenied`` if the existing auth
    /// heuristic matches).
    func resolve<E: AppEntity>(_ entityType: E.Type, id: E.ID) async throws -> E?
}

/// Default resolver that calls `EntityType.defaultQuery.entities(for: [id])`.
///
/// This is the right choice for most production intents — `EntityQuery` is the
/// AppIntents framework's canonical path for id→entity lookup, and hosts that
/// already model their entities via `AppEntity` will have a working query
/// installed.
@available(iOS 26, macOS 26, *)
public struct DefaultAppEntityResolver: AppEntityResolver {
    public init() {}
    public func resolve<E: AppEntity>(_ entityType: E.Type, id: E.ID) async throws -> E? {
        // `defaultQuery` is the framework-blessed lookup path; a host that
        // hasn't wired a query will hit a compile-time error here rather than
        // a confusing runtime failure.
        let results = try await E.defaultQuery.entities(for: [id])
        return results.first
    }
}

public extension CodingUserInfoKey {
    /// `[String: any AppEntity]` keyed by `@Parameter` name — populated by the
    /// executor before invoking `JSONDecoder` so the intent's `init(from:)` can
    /// pluck resolved entities out of `decoder.userInfo` instead of trying to
    /// decode them itself.
    ///
    /// ```swift
    /// init(from decoder: Decoder) throws {
    ///     let c = try decoder.container(keyedBy: CodingKeys.self)
    ///     self.init()
    ///     let resolved = decoder.userInfo[.manifoldResolvedEntities] as? [String: Any] ?? [:]
    ///     if let book = resolved["book"] as? Book { self.book = book }
    /// }
    /// ```
    static let manifoldResolvedEntities = CodingUserInfoKey(rawValue: "com.manifoldkit.appintents.resolvedEntities")!
}

// MARK: - AppIntentToolExecutor

/// Bridges an AppIntent into ManifoldKit's `ToolExecutor` surface so an
/// inference backend can call the intent like any other tool.
///
/// The executor synthesises the JSON-Schema contract from the intent's
/// `@Parameter` metadata via reflection (see ``JSONSchemaBuilder``), decodes
/// the model's argument payload into a fresh intent instance, runs
/// ``AppIntent/perform()``, and serialises the resulting ``IntentResult``
/// into the tool result body.
///
/// ## Requirements
///
/// - `Intent` is an `AppIntent` (provides `init()` + `perform()` + the
///   `@Parameter` declarations).
/// - `Intent` is `Decodable`. AppIntents don't synthesise `Decodable`
///   automatically because the property wrappers shadow the storage; a
///   one-line `init(from decoder:)` is usually enough — see the bundled
///   `ManifoldAppIntents` DocC for the boilerplate.
/// - Enum parameters that should appear as JSON-Schema `enum: [...]` adopt
///   ``IntentEnumParameter`` (a thin marker over `CaseIterable & RawRepresentable`).
///
/// ## Errors
///
/// - JSON-decode failures surface as
///   ``ToolResult/ErrorKind/invalidArguments``.
/// - `IntentAuthorization` failures (i.e. the system or the intent itself
///   throwing the AppIntents authorisation error) surface as
///   ``ToolResult/ErrorKind/permissionDenied``.
/// - Other thrown errors become ``ToolResult/ErrorKind/permanent``.
///
/// ## Cancellation
///
/// The executor honours structured cancellation — the orchestrator's
/// `Task.cancel()` propagates into ``AppIntent/perform()`` via the surrounding
/// task. AppIntent implementations that perform their own work should poll
/// `Task.checkCancellation()` at sensible yield points.
///
/// ## Availability
///
/// Pinned to iOS 26 / macOS 26 because the executor relies on the on-device
/// LLM-actuation features in the latest AppIntents revision. Apps targeting
/// older OS minimums should gate the registration with `if #available`.
@available(iOS 26, macOS 26, *)
public struct AppIntentToolExecutor<Intent: AppIntent & Decodable>: ToolExecutor {

    /// Approval policy for AppIntent-backed tools.
    ///
    /// Use ``requiresUserApproval`` for side-effecting intents (the default),
    /// and ``readOnlyAutoApprove`` only for deliberately read-only intents.
    public enum ApprovalPolicy: Sendable {
        /// Require an explicit ``ToolApprovalGate`` decision per call.
        case requiresUserApproval

        /// Skip approval prompts for read-only intents that are safe to run.
        case readOnlyAutoApprove

        var requiresApproval: Bool {
            switch self {
            case .requiresUserApproval:
                true
            case .readOnlyAutoApprove:
                false
            }
        }
    }

    public let definition: ToolDefinition
    public let requiresApproval: Bool

    /// `@Parameter`-name → `AppEntity` metatype map, captured once at init
    /// from `JSONSchemaBuilder.analyze(...)`. The executor walks this map per
    /// dispatch to pre-resolve `{ "id": ... }` payloads before decode.
    let entityParameters: [String: Any.Type]

    /// Resolver that turns an `AppEntity` id into a concrete instance. Hosts
    /// can swap this for a cache / mock by passing a custom conformance.
    let entityResolver: any AppEntityResolver

    /// Creates an executor that exposes `intentType` as a model-callable tool.
    ///
    /// - Parameters:
    ///   - intentType: The AppIntent type to bridge.
    ///   - description: Optional human-readable description shown to the
    ///     model. Defaults to the intent's ``AppIntent/title`` (resolved via
    ///     `String(localized:)`).
    ///   - approvalPolicy: Approval behavior for this tool. Defaults to
    ///     ``ApprovalPolicy/requiresUserApproval`` because AppIntents often
    ///     trigger external side effects. Opt into
    ///     ``ApprovalPolicy/readOnlyAutoApprove`` only for deliberately
    ///     read-only intents.
    ///   - entityResolver: Resolves `AppEntity` identifier payloads into real
    ///     instances. Defaults to ``DefaultAppEntityResolver`` which dispatches
    ///     through `EntityType.defaultQuery`; supply a custom resolver for
    ///     caches, mocks, or test fixtures.
    public init(
        _ intentType: Intent.Type,
        description: String? = nil,
        approvalPolicy: ApprovalPolicy = .requiresUserApproval,
        entityResolver: any AppEntityResolver = DefaultAppEntityResolver()
    ) {
        let toolName = Self.canonicalName(for: intentType)
        let toolDescription = description ?? Self.defaultDescription(for: intentType)
        let analysis = JSONSchemaBuilder.analyze(for: Intent.self) {
            Intent()
        }
        self.requiresApproval = approvalPolicy.requiresApproval
        self.entityParameters = analysis.entityParameters
        self.entityResolver = entityResolver
        self.definition = ToolDefinition(
            name: toolName,
            description: toolDescription,
            parameters: analysis.schema
        )
    }

    public func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        do {
            try Task.checkCancellation()

            // Pre-resolve any AppEntity parameters. The synthesised schema
            // advertises them as `{ "id": ... }` objects, but `AppEntity` is
            // not generically `Decodable` — we have to translate ids into real
            // entity instances before `JSONDecoder` runs.
            let preparedArguments: JSONSchemaValue
            let resolvedEntities: [String: Any]
            do {
                let (args, entities) = try await resolveEntityArguments(arguments)
                preparedArguments = args
                resolvedEntities = entities
            } catch let error as EntityResolutionFailure {
                return ToolResult(
                    callId: "",
                    content: error.message,
                    errorKind: error.errorKind
                )
            }

            try Task.checkCancellation()

            let intent: Intent
            do {
                intent = try decodeIntent(
                    from: preparedArguments,
                    resolvedEntities: resolvedEntities
                )
            } catch {
                return ToolResult(
                    callId: "",
                    content: "Failed to decode AppIntent arguments: \(error.localizedDescription)",
                    errorKind: .invalidArguments
                )
            }

            try Task.checkCancellation()

            let result = try await intent.perform()
            try Task.checkCancellation()

            return Self.makeToolResult(from: result)
        } catch is CancellationError {
            return ToolResult(callId: "", content: "cancelled by user", errorKind: .cancelled)
        } catch {
            // Authorisation failures route to .permissionDenied so the
            // orchestrator can surface a "grant access" prompt instead of a
            // generic tool-failure message. See `looksLikeAuthorizationFailure`
            // for the heuristic's full contract; in short, we match on
            // `NSError.domain` (locale-safe) and avoid sniffing
            // `localizedDescription` (locale-fragile).
            if Self.looksLikeAuthorizationFailure(error) {
                return ToolResult(
                    callId: "",
                    content: error.localizedDescription,
                    errorKind: .permissionDenied
                )
            }
            return ToolResult(
                callId: "",
                content: error.localizedDescription,
                errorKind: .permanent
            )
        }
    }

    // MARK: - Entity resolution

    /// Failure raised mid-resolution so `execute` can fan it out into a
    /// classified ``ToolResult`` without entangling the happy path.
    private struct EntityResolutionFailure: Error {
        let message: String
        let errorKind: ToolResult.ErrorKind
    }

    /// Walks the executor's entity-parameter map and resolves each
    /// `{ "id": ... }` payload into a real `AppEntity` instance. Returns the
    /// rewritten arguments (entity sub-objects stripped, since `JSONDecoder`
    /// can't decode `AppEntity` directly) plus the resolved-entity map keyed
    /// by parameter name. The intent's `init(from:)` reads the latter via the
    /// decoder's `userInfo`.
    private func resolveEntityArguments(
        _ arguments: JSONSchemaValue
    ) async throws -> (JSONSchemaValue, [String: Any]) {
        // Fast path: no entity parameters — skip the rewrite entirely so
        // existing intents keep their byte-for-byte argument shape.
        guard !entityParameters.isEmpty else {
            return (arguments, [:])
        }
        guard case .object(var rootObject) = arguments else {
            return (arguments, [:])
        }
        var resolved: [String: Any] = [:]
        for (paramName, anyType) in entityParameters {
            // Missing key is fine here — optional entity parameters won't
            // appear at all when the model elects not to supply them.
            guard let entry = rootObject[paramName] else { continue }
            guard case .object(let entryDict) = entry,
                  let idValue = entryDict["id"]
            else {
                throw EntityResolutionFailure(
                    message: "AppEntity parameter \"\(paramName)\" expects an object with an \"id\" field; got \(entry).",
                    errorKind: .invalidArguments
                )
            }
            guard let entityType = anyType as? any AppEntity.Type else {
                // Schema builder shouldn't seed a non-AppEntity here — this
                // is a defensive guard, not a recovery path.
                throw EntityResolutionFailure(
                    message: "Internal error: registered entity type for \"\(paramName)\" is not an AppEntity.",
                    errorKind: .permanent
                )
            }
            let shortName = String(describing: entityType)
            let resolvedEntity: Any?
            do {
                resolvedEntity = try await Self.resolveEntity(
                    entityType,
                    idValue: idValue,
                    resolver: entityResolver
                )
            } catch {
                if Self.looksLikeAuthorizationFailure(error) {
                    throw EntityResolutionFailure(
                        message: error.localizedDescription,
                        errorKind: .permissionDenied
                    )
                }
                throw EntityResolutionFailure(
                    message: "Failed to resolve \(shortName): \(error.localizedDescription)",
                    errorKind: .permanent
                )
            }
            guard let resolvedEntity else {
                throw EntityResolutionFailure(
                    message: "No \(shortName) found for id \(Self.describeId(idValue)).",
                    errorKind: .invalidArguments
                )
            }
            resolved[paramName] = resolvedEntity
            // Drop the entity sub-object — JSONDecoder must not see it.
            rootObject.removeValue(forKey: paramName)
        }
        return (.object(rootObject), resolved)
    }

    /// Generic shim: given an existential `any AppEntity.Type` and a JSON id
    /// value, open the existential into `E: AppEntity`, coerce the id to
    /// `E.ID`, and call the resolver.
    private static func resolveEntity(
        _ entityType: any AppEntity.Type,
        idValue: JSONSchemaValue,
        resolver: any AppEntityResolver
    ) async throws -> Any? {
        try await _resolve(entityType, idValue: idValue, resolver: resolver)
    }

    private static func _resolve<E: AppEntity>(
        _ entityType: E.Type,
        idValue: JSONSchemaValue,
        resolver: any AppEntityResolver
    ) async throws -> E? {
        // `AppEntity.ID` is only constrained to `Hashable & Sendable` — it is
        // not guaranteed `Codable`. We coerce manually for the two id shapes
        // the schema advertises (string + integer); anything else surfaces as
        // an invalid-arguments failure so the model gets a clear signal.
        guard let id = coerceID(idValue, to: E.ID.self) else {
            throw EntityResolutionFailure(
                message: "Could not coerce id \(describeId(idValue)) to \(E.ID.self).",
                errorKind: .invalidArguments
            )
        }
        return try await resolver.resolve(entityType, id: id)
    }

    /// Maps a JSON id payload onto a concrete `E.ID` for the id types we
    /// support: `String`, `Int`, `Int32`, `Int64`, `UInt`, `UInt32`, `UInt64`,
    /// and `UUID`. Returns `nil` when the JSON shape doesn't match the target.
    private static func coerceID<ID>(_ value: JSONSchemaValue, to idType: ID.Type) -> ID? {
        switch value {
        case .string(let s):
            if ID.self == String.self { return s as? ID }
            if ID.self == UUID.self, let uuid = UUID(uuidString: s) { return uuid as? ID }
            // Some intents use String-typed ids that happen to arrive as raw
            // numbers; let the integer branch handle the inverse.
            return nil
        case .number(let n):
            if ID.self == Int.self { return Int(n) as? ID }
            if ID.self == Int32.self { return Int32(n) as? ID }
            if ID.self == Int64.self { return Int64(n) as? ID }
            if ID.self == UInt.self { return UInt(n) as? ID }
            if ID.self == UInt32.self { return UInt32(n) as? ID }
            if ID.self == UInt64.self { return UInt64(n) as? ID }
            if ID.self == Double.self { return n as? ID }
            // Model sometimes returns an integer-as-number when the id is
            // actually a string — accept that too.
            if ID.self == String.self {
                if n.rounded() == n { return String(Int64(n)) as? ID }
                return String(n) as? ID
            }
            return nil
        default:
            return nil
        }
    }

    /// Compact debug string for the id payload — used in error messages.
    private static func describeId(_ idValue: JSONSchemaValue) -> String {
        switch idValue {
        case .string(let s): "\"\(s)\""
        case .number(let n): String(n)
        case .bool(let b): String(b)
        case .null: "null"
        case .array, .object: String(describing: idValue)
        }
    }

    // MARK: - Streaming

    /// Streaming dispatch for AppIntents.
    ///
    /// When `Intent` adopts ``ProgressReportingAppIntent`` (and its
    /// ``ProgressReportingAppIntent/supportsProgressReporting`` flag is `true`),
    /// the executor installs an ``IntentProgressReporter`` into the
    /// ``IntentProgressReporter/current`` task-local before invoking
    /// ``AppIntent/perform()``. Progress events the intent emits inside
    /// `perform()` are forwarded onto the returned stream as
    /// ``ToolExecutionEvent/progress(message:fraction:)`` chunks; the terminal
    /// ``ToolExecutionEvent/completed(_:)`` carries the same ``ToolResult``
    /// the single-shot ``execute(arguments:)`` would have returned.
    ///
    /// Intents that do not adopt the progress protocol fall through to the
    /// default ``ToolExecutor/executeStreaming(arguments:)`` wrapper —
    /// behaviour is identical to the single-shot path with one terminal
    /// `.completed` event.
    ///
    /// Cancellation: the stream's `onTermination` cancels the wrapping task,
    /// which propagates into both `perform()` and the reporter drain loop via
    /// structured concurrency. On cancellation the terminal event is a
    /// ``ToolResult`` with ``ToolResult/ErrorKind/cancelled``, matching the
    /// single-shot contract — the stream finishes cleanly, no throw.
    public func executeStreaming(arguments: JSONSchemaValue) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
        // Fall through to the protocol default when this intent did not opt
        // into progress reporting. Keeps the streaming path uniform for
        // callers without paying for a reporter we'd never feed.
        guard let progressType = Intent.self as? any ProgressReportingAppIntent.Type,
              progressType.supportsProgressReporting
        else {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let result = try await self.execute(arguments: arguments)
                        continuation.yield(.completed(result))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        return AsyncThrowingStream { continuation in
            let reporter = IntentProgressReporter()

            // Drain the reporter's progress stream onto the outer continuation
            // in a sibling task so the executor can run `perform()` and forward
            // chunks concurrently. The drain finishes when `reporter.finish()`
            // closes the underlying AsyncStream, which we call after
            // `perform()` returns or throws.
            let drainTask = Task {
                for await event in reporter.events {
                    continuation.yield(event)
                }
            }

            let workTask = Task {
                // Install the reporter into the task-local so the running
                // intent can pull it via `IntentProgressReporter.current`
                // without a parameter on `perform()`.
                let result = await IntentProgressReporter.$current.withValue(reporter) {
                    await self.runStreaming(arguments: arguments)
                }
                // Close the progress stream so the drain task exits.
                await reporter.finish()
                // Make sure the drain has flushed any in-flight yields before
                // we emit the terminal event — preserves the documented
                // ordering invariant (progress events strictly precede
                // .completed).
                _ = await drainTask.value
                continuation.yield(.completed(result))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                workTask.cancel()
                drainTask.cancel()
            }
        }
    }

    /// Streaming inner loop — runs the intent, classifies the outcome, and
    /// returns the terminal ``ToolResult`` the caller will wrap as
    /// ``ToolExecutionEvent/completed(_:)``.
    ///
    /// Factored out so the cancellation/error classification stays in lockstep
    /// with the single-shot ``execute(arguments:)`` path — both call
    /// ``serialise(_:)`` and ``looksLikeAuthorizationFailure(_:)`` the same
    /// way.
    private func runStreaming(arguments: JSONSchemaValue) async -> ToolResult {
        do {
            try Task.checkCancellation()

            // Mirror `execute(arguments:)` — pre-resolve entity parameters so
            // streaming dispatch honours `@Parameter var book: Book`-style
            // intents that arrive as `{ "id": ... }`. Without this the
            // streaming path would throw a `JSONDecoder` error for any
            // AppEntity parameter; see PR notes for the four-PR landing-wave
            // drift that caused the regression.
            let preparedArguments: JSONSchemaValue
            let resolvedEntities: [String: Any]
            do {
                let (args, entities) = try await resolveEntityArguments(arguments)
                preparedArguments = args
                resolvedEntities = entities
            } catch let error as EntityResolutionFailure {
                return ToolResult(
                    callId: "",
                    content: error.message,
                    errorKind: error.errorKind
                )
            }

            try Task.checkCancellation()

            let intent: Intent
            do {
                intent = try decodeIntent(
                    from: preparedArguments,
                    resolvedEntities: resolvedEntities
                )
            } catch {
                return ToolResult(
                    callId: "",
                    content: "Failed to decode AppIntent arguments: \(error.localizedDescription)",
                    errorKind: .invalidArguments
                )
            }

            try Task.checkCancellation()

            let result = try await intent.perform()
            try Task.checkCancellation()

            // Same dialog/structured branching as the single-shot path so
            // `ProvidesDialog` intents see their dialog text on
            // `ToolResult.dialog` and (for pure-dialog results) mirrored into
            // `content`.
            return Self.makeToolResult(from: result)
        } catch is CancellationError {
            return ToolResult(callId: "", content: "cancelled by user", errorKind: .cancelled)
        } catch {
            if Self.looksLikeAuthorizationFailure(error) {
                return ToolResult(
                    callId: "",
                    content: error.localizedDescription,
                    errorKind: .permissionDenied
                )
            }
            return ToolResult(
                callId: "",
                content: error.localizedDescription,
                errorKind: .permanent
            )
        }
    }

    // MARK: - Shared decode + result-assembly helpers

    /// Encode the (entity-stripped) argument payload back to JSON, hand the
    /// resolved entities to the decoder via `userInfo`, and decode into a
    /// fresh `Intent`. Shared by ``execute(arguments:)`` and
    /// ``runStreaming(arguments:)`` so the two dispatch paths can't drift on
    /// date-strategy / userInfo wiring — the divergence between them was the
    /// regression this PR closes.
    private func decodeIntent(
        from arguments: JSONSchemaValue,
        resolvedEntities: [String: Any]
    ) throws -> Intent {
        // Encode/decode symmetrically with ISO-8601 dates. The synthesised
        // JSON Schema advertises `Date` as
        // `{ "type": "string", "format": "date-time" }`, so models emit
        // ISO-8601 strings — `JSONDecoder`'s default `secondsSince2001`
        // strategy would reject every one of them.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Hand the resolved entities to the host's `init(from:)` via
        // userInfo — see ``CodingUserInfoKey/manifoldResolvedEntities``.
        if !resolvedEntities.isEmpty {
            // `JSONDecoder.userInfo` values must be Sendable in
            // strict-concurrency builds; wrap the heterogeneous entity map
            // in a small Sendable box. Entities flow synchronously into
            // `init(from:)` on the same actor, so `@unchecked Sendable` is
            // safe in this scope.
            decoder.userInfo[.manifoldResolvedEntities] = ResolvedEntityBox(values: resolvedEntities)
        }
        let argsData = try encoder.encode(arguments)
        return try decoder.decode(Intent.self, from: argsData)
    }

    /// Assemble the terminal ``ToolResult`` for a successful `perform()`
    /// outcome. Shared by single-shot and streaming dispatch so both paths
    /// emit identical `content` / `dialog` shapes for `ProvidesDialog` and
    /// `ReturnsValue` results.
    ///
    /// For pure `ProvidesDialog` results without a `ReturnsValue`,
    /// ``serialise(_:)`` falls back to `String(describing:)` which typically
    /// contains the dialog text already, but the model still benefits from
    /// the explicit mirror — surface the dialog in `content` so the model
    /// has something useful to read, and keep `dialog` populated so the host
    /// UI can speak it verbatim.
    static func makeToolResult(from result: some IntentResult) -> ToolResult {
        let dialog = extractDialog(result)
        let structured = serialise(result)
        let content: String
        if let dialog, shouldMirrorDialogIntoContent(result) {
            content = dialog
        } else {
            content = structured
        }
        return ToolResult(callId: "", content: content, errorKind: nil, dialog: dialog)
    }

    // MARK: - Helpers

    /// Tool name derived from the intent's type — `AskManifoldDemoIntent`
    /// becomes `ask_base_chat_demo_intent`. Snake-case keeps the name aligned
    /// with the rest of the ManifoldKit reference toolset.
    static func canonicalName(for type: Intent.Type) -> String {
        let raw = String(describing: type)
        return raw.snakeCased()
    }

    /// Localised title fallback when the caller doesn't provide a description.
    static func defaultDescription(for type: Intent.Type) -> String {
        // `LocalizedStringResource` resolves through the calling bundle; in a
        // test harness the resolution falls back to the literal key, which is
        // still a serviceable description.
        String(localized: type.title)
    }

    /// JSON-encodes a value that conforms to `Encodable`; otherwise returns
    /// `String(describing:)`. AppIntents `IntentResult` is not generically
    /// `Encodable`, but most concrete result types either are codable or have
    /// a sensible `description` representation, and a stringly-typed body is
    /// what the model will read regardless.
    static func serialise(_ result: some IntentResult) -> String {
        // The framework's `IntentResultContainer` is not itself `Encodable`,
        // so the encodable-cast below misses on the most common compound
        // shape (`ReturnsValue<T> & ProvidesDialog`). Pull the structured
        // `value` payload out via reflection first — that's the field the
        // model actually wants to read — and only fall back to encoding the
        // whole result for custom `IntentResult` types that ARE `Encodable`.
        if let value = extractReturnsValue(result) {
            if let encoded = jsonEncode(value) {
                return encoded
            }
            return String(describing: value)
        }
        if let encodable = result as? any Encodable {
            do {
                // Symmetric with the decoder in `execute(arguments:)` — a
                // result that contains a `Date` should serialise as an
                // ISO-8601 string so the model sees the same shape it sent.
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(EncodableBox(encodable))
                if let string = String(data: data, encoding: .utf8) {
                    return string
                }
            } catch {
                // Encoding a custom IntentResult can fail when the
                // concrete type's nested values aren't encodable. We log
                // and fall back to `String(describing:)` so the model
                // still sees something meaningful in the tool output.
                Log.inference.warning(
                    "AppIntentToolExecutor: failed to JSON-encode IntentResult — falling back to description: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return String(describing: result)
    }

    /// Pulls the `ReturnsValue<T>` payload out of a framework
    /// `IntentResultContainer`, or returns `nil` for pure-dialog/no-value
    /// results.
    private static func extractReturnsValue(_ result: some IntentResult) -> Any? {
        let mirror = Mirror(reflecting: result)
        for child in mirror.children where child.label == "value" {
            let inner = Mirror(reflecting: child.value)
            if inner.displayStyle == .optional {
                if inner.children.isEmpty { return nil }
                return inner.children.first?.value
            }
            return child.value
        }
        return nil
    }

    /// JSON-encodes an arbitrary `Encodable` value with ISO-8601 dates,
    /// or returns `nil` if the value isn't `Encodable` or encoding fails.
    private static func jsonEncode(_ value: Any) -> String? {
        guard let encodable = value as? any Encodable else { return nil }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(EncodableBox(encodable))
            return String(data: data, encoding: .utf8)
        } catch {
            Log.inference.warning(
                "AppIntentToolExecutor: failed to JSON-encode ReturnsValue payload: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Pulls the dialog string out of an `IntentResult & ProvidesDialog` using
    /// public APIs only. Returns `nil` when the dialog can't be rendered from
    /// the public surface — pure-dialog intents whose `IntentDialog` storage
    /// isn't reachable via `CustomStringConvertible` or a public
    /// `LocalizedStringResource` will fall through to the content mirror.
    ///
    /// Intentionally does NOT reach into AppIntents framework internals —
    /// private deferred-localization classes have rearranged twice since
    /// iOS 16 and are an App Store / privacy-review hazard. If the public
    /// surface stops yielding the dialog text on a future SDK revision,
    /// the correct fix is to add a public-API path here, not to reintroduce
    /// KVC probing against private class names. See PR #1385 for context.
    static func extractDialog(_ result: some IntentResult) -> String? {
        guard result is any ProvidesDialog else { return nil }

        // Locate the `dialog` child via Mirror — `Mirror` is public stdlib
        // reflection, not private framework API.
        let mirror = Mirror(reflecting: result)
        var dialogValue: Any?
        for child in mirror.children where child.label == "dialog" {
            dialogValue = child.value
            break
        }
        // Some `IntentResult` builders nest the dialog one level deep
        // (e.g. inside a storage struct). Walk one extra layer when we
        // didn't find the field directly on the result.
        if dialogValue == nil {
            for child in mirror.children {
                let inner = Mirror(reflecting: child.value)
                for sub in inner.children where sub.label == "dialog" {
                    dialogValue = sub.value
                    break
                }
                if dialogValue != nil { break }
            }
        }
        guard let dialogValue else { return nil }

        // The found value might be `IntentDialog?` (often `Optional<Any>`
        // at this point). Unwrap one optional layer if needed.
        guard let dialog = Self.unwrapOptional(dialogValue) else { return nil }

        // Path 1: `IntentDialog` conforms to `CustomStringConvertible` on
        // current SDKs. Accept the result only when it doesn't look like the
        // Swift default type-name dump (`IntentDialog(...)`), which would
        // leak framework chrome into the spoken text.
        if let convertible = dialog as? CustomStringConvertible {
            let rendered = convertible.description
            if Self.looksRenderable(rendered, dialog: dialog) {
                return rendered
            }
        }

        // Path 2: walk one mirror level looking for a `LocalizedStringResource`
        // child (public on iOS 16+). Resolve via `String(localized:)`.
        let dialogMirror = Mirror(reflecting: dialog)
        for child in dialogMirror.children {
            if let resource = child.value as? LocalizedStringResource {
                return String(localized: resource)
            }
        }

        return nil
    }

    /// Returns `true` when a `String(describing:)` result is plausible spoken
    /// text — i.e. not the Swift default reflection dump such as
    /// `IntentDialog(...)` or `Optional(IntentDialog(...))`. The check is
    /// deliberately conservative: anything that starts with the dialog's type
    /// name is treated as non-renderable so the caller falls through to the
    /// `LocalizedStringResource` probe or, ultimately, returns `nil`.
    private static func looksRenderable(_ rendered: String, dialog: Any) -> Bool {
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        let typeName = String(describing: type(of: dialog))
        if trimmed.hasPrefix(typeName) { return false }
        if trimmed.hasPrefix("IntentDialog") { return false }
        return true
    }

    /// Peels one layer of `Optional` off an `Any` value via reflection.
    /// Returns `nil` if the optional is `.none`, otherwise the wrapped value.
    private static func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle != .optional { return value }
        return mirror.children.first?.value
    }

    /// `true` when the result has a dialog but no separately-encodable
    /// structured value, i.e. pure `IntentResult & ProvidesDialog` without a
    /// `ReturnsValue<T>` payload. In that case the dialog string is the only
    /// meaningful content for the model to read.
    static func shouldMirrorDialogIntoContent(_ result: some IntentResult) -> Bool {
        // The `ReturnsValue` protocol carries an associated `Value` type, so
        // we can't form `any ReturnsValue` directly — instead probe via a
        // Mirror lookup for a `value` child whose contents are non-nil.
        // `IntentResultContainer` always carries a `value` slot, but for
        // pure-dialog results it holds `Optional<Never>.none`; for
        // `ReturnsValue<T>` results it holds the wrapped payload.
        let mirror = Mirror(reflecting: result)
        for child in mirror.children where child.label == "value" {
            // Optional with displayStyle == .optional and no children means
            // `.none`; any other shape (including a concrete non-optional
            // value) counts as carrying a structured payload.
            let valueMirror = Mirror(reflecting: child.value)
            if valueMirror.displayStyle == .optional, valueMirror.children.isEmpty {
                return true
            }
            return false
        }
        return true
    }

    /// Domain-based heuristic for AppIntents authorisation failures.
    ///
    /// We can't import a concrete typed authorisation error from the
    /// AppIntents framework — neither `AppIntentError`, `IntentError`, nor
    /// `OpenIntentError` exposes an authorisation case in the public SDK
    /// surface as of the iOS 26 / macOS 26 release. Until Apple ships a
    /// stable typed surface, the only locale-safe signal is the `NSError`
    /// domain.
    ///
    /// Two layers, in order:
    ///   1. Exact-match the known authorisation-shaped domains we ship for.
    ///      `LAError` (`com.apple.LocalAuthentication`) covers biometric /
    ///      device-passcode flows. `AppIntentsAuthorizationErrorDomain` is
    ///      the conventional domain string Apple's auth shim emits and
    ///      matches our test fixture.
    ///   2. Substring-match on common authorisation tokens in the domain
    ///      string (`authorization` / `authorisation` / `permission`). This
    ///      catches third-party intents that follow the same naming convention
    ///      without us having to enumerate every framework's domain.
    ///
    /// Limits: errors that surface a custom domain unrelated to authorisation
    /// while carrying an "access denied"-style description in their
    /// `userInfo` will be classified as `.permanent`, not `.permissionDenied`.
    /// That's a deliberate trade: domain identity is locale-safe;
    /// `localizedDescription` is not, and matching English substrings on it
    /// would have us misclassify any user running with a non-English locale.
    static func looksLikeAuthorizationFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        let domain = nsError.domain

        // Known authorisation domains — exact match keeps this immune to
        // domain strings that incidentally contain the same substring (e.g.
        // a hypothetical "MyApp.PermissionGrantedDomain" that fires on
        // success).
        let knownAuthDomains: Set<String> = [
            "com.apple.LocalAuthentication",         // LAError
            "AppIntentsAuthorizationErrorDomain",    // AppIntents auth shim convention
        ]
        if knownAuthDomains.contains(domain) {
            return true
        }

        // Domain-substring fallback for third-party domains that follow the
        // convention (e.g. "com.example.PermissionDeniedError"). Case-
        // insensitive; UK and US spellings both supported.
        let lowered = domain.lowercased()
        return lowered.contains("authorization")
            || lowered.contains("authorisation")
            || lowered.contains("permission")
    }
}

// MARK: - Helpers

private extension String {
    /// `MyIntentName` → `my_intent_name`.
    func snakeCased() -> String {
        var output = ""
        for (index, character) in enumerated() {
            if character.isUppercase && index != 0 {
                output.append("_")
            }
            output.append(character.lowercased())
        }
        return output
    }
}

/// Sendable wrapper around the resolved-entity map handed to the host
/// intent's `init(from:)` via `decoder.userInfo`. `[String: Any]` is not
/// generically `Sendable`, but the contents are read synchronously inside
/// the decoder's call site on the same actor — see ``AppIntentToolExecutor``.
public struct ResolvedEntityBox: @unchecked Sendable {
    public let values: [String: Any]
    public init(values: [String: Any]) { self.values = values }
    /// Pulls a resolved entity out of the box by `@Parameter` name.
    public func entity<E>(_ name: String, as type: E.Type = E.self) -> E? {
        values[name] as? E
    }
}

@available(iOS 26, macOS 26, *)
public extension Decoder {
    /// Convenience accessor for AppIntents `init(from:)` to read a resolved
    /// `AppEntity` that the executor staged into `userInfo`.
    ///
    /// ```swift
    /// init(from decoder: Decoder) throws {
    ///     self.init()
    ///     if let book: Book = decoder.resolvedAppEntity("book") { self.book = book }
    /// }
    /// ```
    func resolvedAppEntity<E: AppEntity>(_ name: String, as type: E.Type = E.self) -> E? {
        guard let box = userInfo[.manifoldResolvedEntities] as? ResolvedEntityBox else {
            return nil
        }
        return box.entity(name, as: E.self)
    }
}

/// Type-erased box so we can call `JSONEncoder().encode(...)` on a value whose
/// concrete type we only know exists at runtime.
private struct EncodableBox: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

#endif // canImport(AppIntents)
