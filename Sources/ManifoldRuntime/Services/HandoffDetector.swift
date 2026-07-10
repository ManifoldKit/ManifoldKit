import Foundation
import ManifoldInference

/// Pure helper that classifies a ``ToolCall`` against a session's agent
/// registry and synthesises the auxiliary strings the executor needs to
/// drive a successful handoff (the prepended instructions block plus the
/// boundary message injected into the next turn's structured history).
///
/// Lives in `ManifoldRuntime` alongside ``HandoffToolSource`` because it
/// operates on the storage-agnostic ``ChatSession`` — the same input
/// the protocol takes — and is consumed by ``ConversationTurnExecutor``.
/// Extracting it from the executor keeps the classification logic unit-
/// testable in isolation (no inference dependency at the test seam).
public enum HandoffDetector {

    /// Prefix the synthesised `transfer_to_<name>` tools share. Held as a
    /// constant so the detector and the tool source agree on the string in
    /// one place.
    public static let transferToolPrefix = "transfer_to_"

    /// Classify a tool call against the session's agent registry.
    ///
    /// - Returns: ``HandoffDetectionResult/handoff(_:)`` when the call's
    ///   name is `transfer_to_<X>` AND `X` matches an agent in
    ///   `session.agents`. Otherwise ``HandoffDetectionResult/regular(_:)``
    ///   so the dispatch loop routes the call through the normal registry.
    public static func classify(
        _ call: ToolCall,
        in session: ChatSession
    ) -> HandoffDetectionResult {
        guard call.toolName.hasPrefix(transferToolPrefix) else {
            return .regular(call)
        }
        let targetName = String(call.toolName.dropFirst(transferToolPrefix.count))
        // Case-insensitive match because the model emits the lower-cased
        // synthesised name from the tool definition, but agents may be
        // registered under any casing. Fall back to the literal name match
        // first so an exact match takes precedence over a case-folded one.
        let target = session.agents.first { $0.name == targetName }
            ?? session.agents.first { $0.name.lowercased() == targetName.lowercased() }
        guard let target else {
            return .regular(call)
        }
        let payload = parsePayload(from: call.arguments)
        return .handoff(AgentHandoff(targetAgentID: target.id, payload: payload))
    }

    /// Build the prepended "Handoff instructions" block listing siblings of
    /// `agent`. Without this block, weak local models often never trigger
    /// a transfer call even when the synthesised tools are advertised
    /// (plan §Handoff semantics — AI-review fix #2).
    ///
    /// Returns the empty string when `siblings` is empty so the executor
    /// can prepend unconditionally without producing stray whitespace.
    public static func handoffInstructions(
        for agent: AgentDefinition,
        siblings: [AgentDefinition]
    ) -> String {
        guard !siblings.isEmpty else { return "" }
        let lines = siblings.map { sibling in
            "- \(sibling.name): \(sibling.description). Call transfer_to_\(sibling.name) when handoff is appropriate."
        }
        return """
        You can hand off to:
        \(lines.joined(separator: "\n"))
        """
    }

    /// Synthesise the system-role boundary message injected into the next
    /// turn's structured history when a handoff occurs (plan AI-review fix
    /// #3). Carries the payload verbatim when present so the new agent sees
    /// an explicit context-handover boundary instead of "what is this
    /// conversation."
    public static func boundaryMessage(
        from previous: AgentDefinition,
        to next: AgentDefinition,
        payload: String?
    ) -> String {
        let header = "[Handoff from \(previous.name) to \(next.name)]"
        guard let payload, !payload.isEmpty else { return header }
        return "\(header) payload: \(payload)"
    }

    // MARK: - Private

    /// Best-effort payload extraction. Tool arguments are JSON-encoded so
    /// the common case is `{"payload": "..."}`. We avoid `try?` (banned in
    /// production) by routing through a typed do/catch that downgrades
    /// decode failures to `nil`, matching the protocol's "payload is
    /// optional" contract.
    private static func parsePayload(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8) else { return nil }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dict = object as? [String: Any] else { return nil }
            return dict["payload"] as? String
        } catch {
            // Arguments may legitimately be empty (`{}`) or non-JSON for
            // some weak models; treat decode failures as "no payload"
            // rather than erroring out — handoff still completes, the
            // boundary message just omits the payload section.
            Log.inference.debug(
                "HandoffDetector: payload parse failed (treated as nil): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
