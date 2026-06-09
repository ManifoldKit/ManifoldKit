import Foundation
import ManifoldInference

/// Named seam for the per-turn session-tool dispatch wiring that previously
/// lived inline in ``ConversationTurnExecutor``. It owns the three-step lifecycle
/// the turn loop depends on:
///
///   1. **advertise** — ``advertisedToolDefinitions(sessionToolSources:sessionRecord:)``
///      unions the base registry's `advertisedDefinitions` with each
///      ``SessionToolSource``'s per-session contributions, applies the
///      allowed-tools intersection, and truncates to the backend's
///      `maxAdvertisedToolCount` cap. This is what goes on the wire as
///      `GenerationConfig.tools`.
///   2. **register** — ``registerSessionToolExecutors(sources:sessionRecord:)``
///      installs a ``SessionToolSourceExecutor`` for each advertised source tool
///      on `InferenceService.toolRegistry`. This MUST happen *before*
///      `enqueueAsync`, else the dispatch loop returns `unknownTool` (#1606).
///   3. **unregister** — ``unregisterSessionToolExecutors(_:)`` removes exactly
///      the names this binder registered once the stream has fully drained, so a
///      session-scoped executor never leaks a stale ``ChatSession`` into the next
///      turn.
///
/// Execution of the tool calls themselves happens producer-side in
/// `ManifoldInference`'s GenerationQueue dispatch loop — this binder only
/// advertises and binds. Like the per-turn `setHandoffDetector` /
/// `setPreToolUseHook` wiring, register/unregister mutate shared
/// `InferenceService` state and assume one turn per service at a time;
/// concurrent turns are last-writer-wins.
struct SessionToolDispatchBinder: Sendable {
    private let inferenceService: InferenceService

    init(inferenceService: InferenceService) {
        self.inferenceService = inferenceService
    }

    /// Builds the advertised tool surface for this turn. See the type doc for
    /// the union/intersection/cap semantics. Fetched on the main actor because
    /// the registry and `InferenceService` accessors are MainActor-isolated.
    func advertisedToolDefinitions(
        sessionToolSources: [any SessionToolSource],
        sessionRecord: ChatSession?
    ) async -> [ToolDefinition] {
        // Base registry definitions — host-installed tools the executor
        // already advertises today. Read from MainActor.
        let registryDefinitions: [ToolDefinition] = await MainActor.run {
            inferenceService.toolRegistry?.advertisedDefinitions ?? []
        }

        // Per-session source contributions. Each source's
        // `toolDefinitions(for:)` returns the definitions it owns for this
        // session — e.g. ``HandoffToolSource`` synthesising one
        // `transfer_to_<name>` per non-active agent. Skipped when we don't
        // have a session record to scope the query.
        var sourceDefinitions: [ToolDefinition] = []
        if let sessionRecord {
            for source in sessionToolSources {
                let defs = await source.toolDefinitions(for: sessionRecord)
                sourceDefinitions.append(contentsOf: defs)
            }
        }

        // Union — sources can override the registry's view of a tool of
        // the same name by appearing later, but in practice the namespaces
        // don't overlap (registry: bespoke executors; sources: synthesised
        // tools). De-dupe by name to keep the wire shape stable.
        var unioned: [ToolDefinition] = registryDefinitions
        var seen = Set(registryDefinitions.map(\.name))
        for def in sourceDefinitions where !seen.contains(def.name) {
            unioned.append(def)
            seen.insert(def.name)
        }

        // Apply allowed-tools intersection across sources. A `nil` return
        // from `allowedToolNames(for:)` means "no restriction" — only
        // non-nil sets participate in the intersection. Skills uses this
        // to clamp the model's tool surface while a skill is active.
        if let sessionRecord {
            var allowList: Set<String>? = nil
            for source in sessionToolSources {
                if let allowed = await source.allowedToolNames(for: sessionRecord) {
                    if let current = allowList {
                        allowList = current.intersection(allowed)
                    } else {
                        allowList = allowed
                    }
                }
            }
            if let allowList {
                unioned = unioned.filter { allowList.contains($0.name) }
            }
        }

        // When the active backend declares a hard cap on how many tools it can
        // handle per turn, truncate the list before building the GenerationConfig.
        // The definitions are already sorted alphabetically by ToolRegistry, so
        // `prefix` always picks the same lexicographically-first N tools —
        // deterministic ordering keeps the "X of Y tools enabled" UI stable.
        let cap = await MainActor.run { inferenceService.capabilities?.maxAdvertisedToolCount }
        if let cap, unioned.count > cap {
            return Array(unioned.prefix(cap))
        }
        return unioned
    }

    /// Registers a ``ToolExecutor`` adapter for each session-source-advertised
    /// tool so a model tool call actually reaches the source's `resolve`
    /// instead of coming back as ``ToolResult/ErrorKind/unknownTool`` (#1606).
    ///
    /// Returns the set of tool names this call registered so the caller can
    /// unregister exactly those when the turn ends — leaving a session-scoped
    /// executor in the shared registry would bind later turns to a stale
    /// ``ChatSession``.
    ///
    /// A tool already present in the registry (a host-installed executor) is
    /// left untouched: the registry executor wins, matching the
    /// advertising-path de-dupe in ``advertisedToolDefinitions``.
    func registerSessionToolExecutors(
        sources: [any SessionToolSource],
        sessionRecord: ChatSession?
    ) async -> Set<String> {
        guard let sessionRecord, !sources.isEmpty else { return [] }

        // Gather (source, definition) pairs off the main actor so the
        // per-source async `toolDefinitions(for:)` calls don't pin MainActor.
        var pairs: [(source: any SessionToolSource, definition: ToolDefinition)] = []
        for source in sources {
            let defs = await source.toolDefinitions(for: sessionRecord)
            for def in defs {
                pairs.append((source, def))
            }
        }
        guard !pairs.isEmpty else { return [] }

        return await MainActor.run {
            guard let registry = inferenceService.toolRegistry else { return Set<String>() }
            var registered: Set<String> = []
            for pair in pairs {
                // Don't clobber a host-installed executor of the same name.
                guard registry.contains(name: pair.definition.name) == false else { continue }
                registry.register(
                    SessionToolSourceExecutor(
                        definition: pair.definition,
                        source: pair.source,
                        session: sessionRecord
                    )
                )
                registered.insert(pair.definition.name)
            }
            return registered
        }
    }

    func unregisterSessionToolExecutors(_ names: Set<String>) async {
        guard !names.isEmpty else { return }
        await MainActor.run {
            guard let registry = inferenceService.toolRegistry else { return }
            for name in names {
                registry.unregister(name: name)
            }
        }
    }
}
