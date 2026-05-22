import Foundation
import ObjectiveC
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

    /// Pulls the dialog string out of an `IntentResult & ProvidesDialog`, or
    /// returns `nil` when the result doesn't carry a dialog channel.
    ///
    /// `IntentDialog`'s public surface has shifted across AppIntents SDK
    /// revisions — earlier versions expose a `full: LocalizedStringResource`,
    /// newer ones store the resolved string privately and surface it via
    /// `String(describing:)`. To stay stable across SDK versions we reflect
    /// on the `IntentDialog` value: if its `Mirror` exposes a child labelled
    /// `full` whose value is a `LocalizedStringResource`, we resolve it; if
    /// that child holds a `String` we return it directly; otherwise we fall
    /// back to `String(describing:)` so something useful still reaches the
    /// host. The limitation is documented here rather than crashing on a
    /// missing private field.
    static func extractDialog(_ result: some IntentResult) -> String? {
        // `ProvidesDialog` is a marker protocol — it doesn't surface a
        // typed accessor for the dialog string, and the `IntentResult`
        // value stores the dialog internally. Reflect on the result to
        // find a child labelled `dialog` whose value is an `IntentDialog`.
        guard result is any ProvidesDialog else { return nil }
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

        // The found value might be `IntentDialog?` (often `Optional<Any>` at
        // this point). Unwrap one optional layer if needed.
        let unwrapped = Self.unwrapOptional(dialogValue)
        guard let dialog = unwrapped else { return nil }

        // `IntentDialog`'s internal layout has shifted between SDK
        // revisions — earlier builds expose a `full: LocalizedStringResource`
        // child directly; current builds (iOS 26 / macOS 26) wrap the
        // resource inside a `storage: .dialog(LNStaticDeferredLocalizedString)`
        // enum that itself stores a `localizedStringResource`. Walk the
        // mirror tree until we find any `LocalizedStringResource` and
        // resolve it via `String(localized:)`.
        if let resolved = Self.findLocalizedString(in: dialog, depth: 0) {
            return resolved
        }
        // Stable public fallback when the private storage layout changes
        // beyond what the recursive walk can decode. Documented limitation:
        // the resulting string contains additional `IntentDialog(...)`
        // chrome rather than just the spoken text.
        return String(describing: dialog)
    }

    /// Depth-bounded recursive mirror walk that returns the first
    /// `LocalizedStringResource` (resolved) or bare `String` it finds.
    /// Bounded to avoid pathological cycles in unknown SDK layouts.
    ///
    /// Current iOS 26 / macOS 26 AppIntents wraps the dialog text in a
    /// private ObjC class (`LNStaticDeferredLocalizedString`) that
    /// exposes the resource through KVC under the
    /// `localizedStringResource` key — we probe that path before falling
    /// back to a Swift-reflection walk for older or future SDK shapes.
    private static func findLocalizedString(in value: Any, depth: Int) -> String? {
        if depth > 6 { return nil }
        if let resource = value as? LocalizedStringResource {
            return String(localized: resource)
        }
        if let str = value as? String, !str.isEmpty {
            return str
        }
        // ObjC bridge: AppIntents' deferred-localized-string holders are
        // NSObject subclasses with a `localizedStringResource` KVC key, and
        // the returned `_NSStringLocalizationResource` exposes the actual
        // Swift `LocalizedStringResource` under the `wrapped` KVC key.
        if let nsObject = value as? NSObject {
            // Try known KVC keys first.
            for key in ["localizedStringResource", "wrapped", "value", "localizedString"] {
                if nsObject.responds(to: NSSelectorFromString(key)) {
                    let next = nsObject.value(forKey: key)
                    if let resource = next as? LocalizedStringResource {
                        return String(localized: resource)
                    }
                    if let next, let found = findLocalizedString(in: next, depth: depth + 1) {
                        return found
                    }
                }
            }
            // Last-resort: enumerate ObjC ivars/properties.
            var count: UInt32 = 0
            if let propList = class_copyPropertyList(type(of: nsObject), &count) {
                defer { free(propList) }
                for i in 0..<Int(count) {
                    let prop = propList[i]
                    let name = String(cString: property_getName(prop))
                    let next = nsObject.value(forKey: name)
                    if let resource = next as? LocalizedStringResource {
                        return String(localized: resource)
                    }
                    if let next, let found = findLocalizedString(in: next, depth: depth + 1) {
                        return found
                    }
                }
            }
            var ivarCount: UInt32 = 0
            if let ivarList = class_copyIvarList(type(of: nsObject), &ivarCount) {
                defer { free(ivarList) }
                for i in 0..<Int(ivarCount) {
                    guard let namePtr = ivar_getName(ivarList[i]) else { continue }
                    let name = String(cString: namePtr)
                    let key = name.hasPrefix("_") ? String(name.dropFirst()) : name
                    if nsObject.responds(to: NSSelectorFromString(key)) {
                        let next = nsObject.value(forKey: key)
                        if let resource = next as? LocalizedStringResource {
                            return String(localized: resource)
                        }
                        if let next, let found = findLocalizedString(in: next, depth: depth + 1) {
                            return found
                        }
                    }
                }
            }
        }
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            if let resource = child.value as? LocalizedStringResource {
                return String(localized: resource)
            }
            // Prefer a child explicitly labelled `full` if its value is a
            // plain String — older SDK shape.
            if child.label == "full", let str = child.value as? String {
                return str
            }
            if let found = findLocalizedString(in: child.value, depth: depth + 1) {
                return found
            }
        }
        return nil
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
