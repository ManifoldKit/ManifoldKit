import Foundation
import ManifoldInference

// MARK: - RuntimeBindingsBox
//
// Mutable holder for per-session knobs that the host wants to swap on a live
// `ConversationRuntime` instance without rebuilding the runtime.
//
// Today this covers two surfaces:
//   - `sessionToolSources`: the per-session tool contributors folded into the
//     advertised tool list each turn (Skills, handoff).
//   - `hookRegistry`: the registry consulted for `preToolUse` sanitisation and
//     the observational `preCompact` event.
//
// `ConversationRuntime` is `Sendable` and its executor is a `struct` with
// `let` fields — neither can hold mutable state directly. The box is an
// actor (same pattern as ``InFlightStreamRegistry``) so the executor's
// per-turn reads serialise cleanly with the host's mutator calls, no lock
// required.
//
// Bindings are read once per turn at the top of the send loop, so an
// update applied between turns takes effect on the next turn without
// touching an in-flight stream. Hosts that need mid-stream rebind would
// have to cancel and restart — that's deliberate.
actor RuntimeBindingsBox {
    private var sessionToolSources: [any SessionToolSource]
    private var hookRegistry: HookRegistry?

    init(
        sessionToolSources: [any SessionToolSource] = [],
        hookRegistry: HookRegistry? = nil
    ) {
        self.sessionToolSources = sessionToolSources
        self.hookRegistry = hookRegistry
    }

    func snapshot() -> (sources: [any SessionToolSource], hooks: HookRegistry?) {
        (sessionToolSources, hookRegistry)
    }

    func updateSessionToolSources(_ sources: [any SessionToolSource]) {
        sessionToolSources = sources
    }

    func updateHookRegistry(_ registry: HookRegistry?) {
        hookRegistry = registry
    }
}
