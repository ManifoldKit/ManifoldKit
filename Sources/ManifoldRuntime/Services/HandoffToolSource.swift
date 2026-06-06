import Foundation
import ManifoldInference

/// Synthesises one `transfer_to_<agent.name>` tool definition for each
/// non-active agent in the session's registry. The dispatch loop intercepts
/// matching tool calls upstream and routes them to ``HandoffDetector``
/// rather than to ``resolve(toolName:arguments:session:)`` — see
/// ``HandoffSourceError/handoffMustBeInterceptedUpstream(_:)``.
///
/// Plan §Architecture — `agents.count > 4` is a soft cap: the source still
/// returns every transfer tool but logs a warning so observers can spot a
/// pathological tool-budget shape before the prompt-cache hit rate craters.
public final class HandoffToolSource: SessionToolSource, @unchecked Sendable {

    /// Soft cap on per-session agent registry size — exceeding it logs a
    /// warning but does not truncate the advertised list. See
    /// ``HandoffToolSource`` discussion above for the rationale.
    public static let agentCountSoftCap: Int = 4

    public init() {}

    public func toolDefinitions(for session: ChatSession) async -> [ToolDefinition] {
        // Single-agent (or empty) sessions have no peer to transfer to.
        guard session.agents.count > 1 else { return [] }

        if session.agents.count > Self.agentCountSoftCap {
            Log.inference.warning(
                "HandoffToolSource: session \(session.id, privacy: .private) has \(session.agents.count, privacy: .public) agents — exceeds soft cap \(Self.agentCountSoftCap, privacy: .public); per-turn tool budget will grow accordingly"
            )
        }

        let activeID = session.activeAgentID
        return session.agents
            .filter { $0.id != activeID }
            .map { agent in
                ToolDefinition(
                    name: "\(HandoffDetector.transferToolPrefix)\(agent.name)",
                    description: "Hand off the conversation to agent '\(agent.name)'. \(agent.description)",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "payload": .object([
                                "type": .string("string"),
                                "description": .string("Optional context to pass to the receiving agent (research outline, summary, etc.).")
                            ])
                        ])
                    ])
                )
            }
    }

    public func resolve(
        toolName: String,
        arguments: String,
        session: ChatSession
    ) async throws -> ToolResult {
        // Handoff tools must be intercepted upstream by the dispatch loop's
        // ``HandoffDetector`` integration — reaching `resolve` means the
        // executor was not configured with a handoff detector, which is a
        // wiring bug rather than a user-facing failure. Throw a typed
        // error so adapters can route it to a diagnostic path.
        if toolName.hasPrefix(HandoffDetector.transferToolPrefix) {
            throw HandoffSourceError.handoffMustBeInterceptedUpstream(toolName)
        }
        throw HandoffSourceError.unknownTransferTarget(toolName)
    }
}

/// Errors thrown by ``HandoffToolSource``. Surfaced as typed values so the
/// runtime can distinguish a "missing wiring" bug (handoff tool reached
/// dispatch instead of being intercepted) from a routing miss against the
/// session's agent registry.
public enum HandoffSourceError: Error, Equatable, Sendable {
    /// A `transfer_to_<name>` tool name reached ``HandoffToolSource/resolve``
    /// instead of being short-circuited by ``HandoffDetector``. Indicates
    /// the executor is missing the detector wiring rather than a model
    /// emitting a bogus tool name.
    case handoffMustBeInterceptedUpstream(String)

    /// A tool name was routed to ``HandoffToolSource`` that does not match
    /// the `transfer_to_` prefix at all — defensive case for the
    /// "I never advertised this tool, why am I being asked to dispatch it"
    /// path the SessionToolSourceContract pins.
    case unknownTransferTarget(String)
}
