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
public struct HandoffChipView: View {

    public let from: AgentDefinition?
    public let to: AgentDefinition?

    public init(from: AgentDefinition?, to: AgentDefinition?) {
        self.from = from
        self.to = to
    }

    public var body: some View {
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
