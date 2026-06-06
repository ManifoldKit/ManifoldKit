import Foundation
import ManifoldInference

/// Bridges a ``SessionToolSource`` into the ``ToolExecutor`` protocol so an
/// advertised session tool actually *dispatches* when the model calls it.
///
/// ## Why this exists (#1606)
///
/// `SessionToolSource` advertises tool definitions (`toolDefinitions(for:)`)
/// *and* declares a `resolve(toolName:arguments:session:)` dispatch hook. The
/// turn loop's advertising path (`ConversationTurnExecutor`) wires the former
/// onto the wire, but nothing ever called `resolve`: tool dispatch flows
/// exclusively through ``ToolRegistry`` → ``ToolExecutor``. A source such as
/// ``ImageGenerationToolSource`` therefore advertised `generate_image` to the
/// model, but when the model called it the dispatch loop looked the name up in
/// the registry, found no executor, and returned
/// ``ToolResult/ErrorKind/unknownTool`` — the source's `resolve` was dead code.
///
/// This adapter closes that gap: ``ConversationTurnExecutor`` registers one
/// `SessionToolSourceExecutor` per advertised session-source tool at the top of
/// a turn and unregisters it when the turn ends, so a model tool call lands on
/// the source's `resolve` and returns a real result.
///
/// Handoff sources (``HandoffToolSource``) are unaffected: their
/// `transfer_to_<agent>` tools are intercepted upstream by the dispatch loop's
/// `HandoffDetector` before the registry is consulted, so the executor this
/// adapter installs for them is never invoked.
struct SessionToolSourceExecutor: ToolExecutor {

    let definition: ToolDefinition

    /// Session-source tools are treated as side-effecting by default: the
    /// runtime relies on the source's own `resolve` to decide what to do, and
    /// dispatch must reach it without a UI approval hop (matching the
    /// "no user interaction" contract of ``ImageGenerationToolSource`` and
    /// friends). Sources that want approval gating can model it inside
    /// `resolve` directly.
    var requiresApproval: Bool { false }

    private let source: any SessionToolSource
    private let session: ChatSession

    init(
        definition: ToolDefinition,
        source: any SessionToolSource,
        session: ChatSession
    ) {
        self.definition = definition
        self.source = source
        self.session = session
    }

    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        // `SessionToolSource.resolve` takes the raw JSON argument *string* the
        // model emitted; ``ToolRegistry`` hands executors an already-parsed
        // ``JSONSchemaValue`` (after optional coercion), so re-serialise it
        // back to a compact JSON string for the source. A `nil`/encode failure
        // is surfaced as an empty object so the source still gets a
        // well-formed payload rather than garbage.
        let argumentString = encodeArguments(arguments)
        return try await source.resolve(
            toolName: definition.name,
            arguments: argumentString,
            session: session
        )
    }

    private func encodeArguments(_ arguments: JSONSchemaValue) -> String {
        do {
            let data = try JSONEncoder().encode(arguments)
            return String(decoding: data, as: UTF8.self)
        } catch {
            // JSONSchemaValue is always encodable, but degrade to an empty
            // object instead of throwing so a serialisation hiccup never turns
            // a real tool call into a permanent failure before the source runs.
            Log.inference.warning(
                "SessionToolSourceExecutor: failed to re-encode arguments for '\(definition.name, privacy: .public)'; passing empty object"
            )
            return "{}"
        }
    }
}
