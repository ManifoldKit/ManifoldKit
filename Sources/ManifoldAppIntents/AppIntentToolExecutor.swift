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

            let content = Self.serialise(result)
            return ToolResult(callId: "", content: content, errorKind: nil)
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
