import Foundation
import ManifoldInference

#if canImport(AppIntents)
import AppIntents
#endif

#if canImport(AppIntents)

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
    public init(
        _ intentType: Intent.Type,
        description: String? = nil,
        approvalPolicy: ApprovalPolicy = .requiresUserApproval
    ) {
        let toolName = Self.canonicalName(for: intentType)
        let toolDescription = description ?? Self.defaultDescription(for: intentType)
        let parameters = JSONSchemaBuilder.schema(for: Intent.self) {
            Intent()
        }
        self.requiresApproval = approvalPolicy.requiresApproval
        self.definition = ToolDefinition(
            name: toolName,
            description: toolDescription,
            parameters: parameters
        )
    }

    public func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        do {
            try Task.checkCancellation()

            let intent: Intent
            do {
                // Encode/decode symmetrically with ISO-8601 dates. The
                // synthesised JSON Schema advertises `Date` as
                // `{ "type": "string", "format": "date-time" }`, so models
                // emit ISO-8601 strings — `JSONDecoder`'s default
                // `secondsSince2001` strategy would reject every one of them.
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let argsData = try encoder.encode(arguments)
                intent = try decoder.decode(Intent.self, from: argsData)
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

            let dialog = Self.extractDialog(result)
            let structured = Self.serialise(result)
            // For pure `ProvidesDialog` results without a `ReturnsValue`,
            // `serialise(_:)` falls back to `String(describing:)` which
            // typically contains the dialog text already, but the model
            // still benefits from the explicit mirror — surface the dialog
            // in `content` so the model has something useful to read, and
            // keep `dialog` populated so the host UI can speak it verbatim.
            let content: String
            if let dialog, Self.shouldMirrorDialogIntoContent(result) {
                content = dialog
            } else {
                content = structured
            }
            return ToolResult(callId: "", content: content, errorKind: nil, dialog: dialog)
        } catch is CancellationError {
            return ToolResult(callId: "", content: "cancelled by user", errorKind: .cancelled)
        } catch {
            // The AppIntents framework surfaces authorisation failures via
            // its own error types. We can't import every concrete
            // authorisation error symbol across SDK versions, so we sniff
            // the error description / domain for the canonical
            // "authorization" / "authorisation" / "permission" / "denied"
            // tokens and route those to .permissionDenied. Everything else
            // falls through to .permanent.
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

    /// Heuristic match for AppIntents authorisation failures.
    static func looksLikeAuthorizationFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        let domain = nsError.domain.lowercased()
        if domain.contains("authorization") || domain.contains("authorisation") || domain.contains("permission") {
            return true
        }
        let description = error.localizedDescription.lowercased()
        return description.contains("not authorized")
            || description.contains("not authorised")
            || description.contains("permission denied")
            || description.contains("authorization required")
            || description.contains("authorisation required")
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
