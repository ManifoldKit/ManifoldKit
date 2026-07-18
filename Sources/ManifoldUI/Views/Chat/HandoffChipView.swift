import SwiftUI
import ManifoldInference

/// Inter-bubble chip rendered at agent transitions in the persisted message
/// sequence. Derived purely from the `agentID` attribution on adjacent
/// ``ChatMessage`` values — the chip is **not** wired to the
/// ``ManifoldRuntime/ConversationEvent/agentHandoff(from:to:)`` event stream.
///
/// Why decouple from the event stream? Events fire during live generation;
/// the persisted sequence is what the user actually sees when they scroll
/// back through history. Tying the chip to event timing would mean
/// reconstructed sessions (scrollback, exports, fresh app launches) would
/// silently lose their chips. Tying it to attribution means the chip is a
/// pure function of the data on disk.
///
/// The chip is suppressed when `from == nil` (first message in a sequence)
/// or when `to == nil` (cannot resolve target agent — fail soft, no chip).
package struct HandoffChipView: View {

    package let from: AgentDefinition?
    package let to: AgentDefinition?

    package init(from: AgentDefinition?, to: AgentDefinition?) {
        self.from = from
        self.to = to
    }

    package var body: some View {
        // Suppress the chip when we cannot identify both sides of the transition.
        // First-message-of-sequence (`from == nil`) is a common case; do not
        // render a half-formed chip.
        if let to, from != nil {
            chip(to: to)
        }
    }

    @ViewBuilder
    private func chip(to: AgentDefinition) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("to \(to.name)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.fill.quaternary, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Handoff to \(to.name)")
        .accessibilityIdentifier("handoff-chip-\(to.id.uuidString)")
    }
}

#Preview {
    let agentA = AgentDefinition(name: "Researcher", systemPrompt: "", description: "")
    let agentB = AgentDefinition(name: "Writer", systemPrompt: "", description: "")
    return VStack {
        HandoffChipView(from: agentA, to: agentB)
        HandoffChipView(from: agentB, to: agentA)
    }
}

/// Session-level "Branched from ‹session›" origin chip
/// (`docs/UI-REFRESH-2026.md` §12 — "branched sessions open with a 'Branched
/// from ‹session›' origin chip (sibling navigation is explicit future
/// work)"). Reuses ``HandoffChipView``'s chip shape/token treatment; this
/// type is a sibling rather than a case on that view because the two chips
/// answer different questions — this one is about *session* provenance
/// (rendered once, at the top of a branched session's transcript), the
/// other is about *agent* provenance (rendered per adjacent-message pair).
///
/// ## Data gap (reported to the orchestrator)
///
/// `ChatSession` carries no "branched from" field today —
/// `SessionBranchCoordinator.branch(sourceSessionID:branchMessageID:newSessionID:newSessionTitle:)`
/// (`Sources/ManifoldRuntime/Services/SessionBranchCoordinator.swift`)
/// creates the new session and copies history into it but never persists a
/// pointer back to `sourceSessionID` — there is no `ChatSession.branchOrigin`
/// (or equivalent) column, and no tranche in `docs/UI-REFRESH-2026-PLAN.md`
/// §L1–L5 owns adding one (it would be a `ManifoldInference`/persistence
/// schema change, well outside this tranche's owned UI paths). This view
/// therefore takes the origin session's title as a plain `String?` so a host
/// that *does* have provenance data (e.g. one that stores it out-of-band)
/// can render the chip today; wiring it to a real, persisted source requires
/// a schema addition that belongs to a future tranche/PR.
package struct BranchOriginChipView: View {

    /// Title of the session this one was branched from. `nil` suppresses the
    /// chip (mirrors ``HandoffChipView``'s own fail-soft suppression).
    package let originSessionTitle: String?

    package init(originSessionTitle: String?) {
        self.originSessionTitle = originSessionTitle
    }

    package var body: some View {
        if let originSessionTitle {
            chip(originTitle: originSessionTitle)
        }
    }

    @ViewBuilder
    private func chip(originTitle: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Branched from \(originTitle)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.fill.quaternary, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Branched from \(originTitle)")
        .accessibilityIdentifier("branch-origin-chip")
    }
}

#Preview("Branch origin") {
    VStack {
        BranchOriginChipView(originSessionTitle: "Planning the Q3 roadmap")
        BranchOriginChipView(originSessionTitle: nil) // suppressed
    }
}
