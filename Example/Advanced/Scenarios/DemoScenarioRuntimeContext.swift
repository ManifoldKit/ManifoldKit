import Foundation
import ManifoldInference
import ManifoldRuntime

/// Richer configuration context a ``DemoScenario`` populates before its
/// turn loop runs.
///
/// Closes the W3B runtime-wiring deferral (Wave 4 of the
/// `put-an-implementation-plan-reactive-penguin.md` plan). Before this
/// type existed, ``DemoScenario/configure`` could only install variant
/// tool executors against a `ToolRegistry` — there was no path to attach
/// the per-session ``SessionToolSource``, ``HookRegistry``, agent roster,
/// or active-agent pointer that Wave 2 introduced. As a result, the three
/// W3B demo cards (`skill-explain`, `handoff-research-write`,
/// `hook-input-sanitize`) compiled but did not actually exercise the
/// Wave 2 surfaces against a live runtime.
///
/// The runner builds a fresh context per invocation, lets the scenario
/// mutate it in-place, then:
///
/// 1. Applies ``agents`` and ``activeAgentID`` to the just-created
///    ``ChatSession`` via the supplied ``SessionStore``.
/// 2. Surfaces ``sessionToolSources`` and ``hookRegistry`` as fields the
///    host can read to decide whether to spin a scenario-scoped
///    ``ConversationRuntime`` (today the demo shares one runtime across
///    all scenarios, so these fields are observed but not yet bound to
///    the live runtime — a follow-up will plumb them through
///    `ManifoldBootstrap`).
///
/// The fields are `var` and `append`-friendly so multiple scenarios that
/// share a configure helper can compose without overwriting each other.
@MainActor
public struct DemoScenarioRuntimeContext {

    /// Shared tool registry — same instance every scenario sees, so a
    /// `configure` closure can install or override executors for variant
    /// behaviour (e.g. a deliberately-slow `sample_repo_search`).
    public let toolRegistry: ToolRegistry

    /// Append-friendly list of per-session tool sources. A scenario that
    /// needs `transfer_to_<agent>` synthesis adds a ``HandoffToolSource``
    /// here; one that wants skills adds a ``SkillToolSource``. Empty by
    /// default.
    public var sessionToolSources: [any SessionToolSource]

    /// Optional hook registry the scenario wants installed (e.g. a
    /// `preToolUse` sanitiser). `nil` means the scenario opts out of
    /// hooks; the runtime falls back to its default no-op shape.
    public var hookRegistry: HookRegistry?

    /// Agents to attach to the freshly-created ``ChatSession``. The
    /// runner applies these via ``SessionStore/updateSession(_:)`` after
    /// `configure` returns, before the first prompt is sent.
    public var agents: [AgentDefinition]

    /// Initial active agent for the session. Must reference an `id` in
    /// ``agents`` — the runner logs a warning and clears the pointer on
    /// mismatch rather than persisting a dangling reference.
    public var activeAgentID: UUID?

    public init(
        toolRegistry: ToolRegistry,
        sessionToolSources: [any SessionToolSource] = [],
        hookRegistry: HookRegistry? = nil,
        agents: [AgentDefinition] = [],
        activeAgentID: UUID? = nil
    ) {
        self.toolRegistry = toolRegistry
        self.sessionToolSources = sessionToolSources
        self.hookRegistry = hookRegistry
        self.agents = agents
        self.activeAgentID = activeAgentID
    }
}
