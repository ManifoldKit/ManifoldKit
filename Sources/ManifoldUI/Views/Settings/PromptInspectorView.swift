import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// A sheet view that displays the fully assembled prompt broken down by slot.
///
/// Shows a token budget bar at the top with colored segments for each slot,
/// an expandable list of slots with content previews, and a summary footer.
/// Designed for debugging and understanding how the prompt is assembled.
public struct PromptInspectorView: View {

    @Environment(\.dismiss) private var dismiss

    /// The assembled prompt to inspect. When `nil`, a placeholder is shown.
    public let assembledPrompt: AssembledPrompt?

    /// Maximum context size for computing the budget bar proportions.
    public let contextSize: Int

    @State private var expandedSlots: Set<String> = []

    public init(assembledPrompt: AssembledPrompt?, contextSize: Int) {
        self.assembledPrompt = assembledPrompt
        self.contextSize = contextSize
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let prompt = assembledPrompt {
                    inspectorContent(prompt)
                } else {
                    noDataView
                }
            }
            .navigationTitle("Prompt Inspector")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - No Data

    private var noDataView: some View {
        ContentUnavailableView {
            Label("No Prompt Data", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Send a message to generate a prompt assembly. The inspector will show slot-by-slot token usage once the assembler is active.")
        }
    }

    // MARK: - Inspector Content

    private func inspectorContent(_ prompt: AssembledPrompt) -> some View {
        Form {
            Section("Token Budget") {
                tokenBudgetBar(prompt)
                    .padding(.vertical, 4)
            }

            Section("Slots") {
                ForEach(prompt.orderedSlots) { slot in
                    slotRow(slot)
                }
            }

            Section("Summary") {
                LabeledContent("Total Tokens") {
                    Text("\(prompt.totalTokens) / \(contextSize)")
                        .monospacedDigit()
                }
                .accessibilityLabel("Total tokens used: \(prompt.totalTokens) of \(contextSize)")

                LabeledContent("History Messages") {
                    Text("\(prompt.messages.count)")
                        .monospacedDigit()
                }
                .accessibilityLabel("\(prompt.messages.count) history messages included")

                LabeledContent("Context Usage") {
                    let ratio = contextSize > 0
                        ? Double(prompt.totalTokens) / Double(contextSize)
                        : 0
                    Text("\(Int(ratio * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(ratio >= 0.95 ? .red : ratio >= 0.80 ? .yellow : .green)
                }
                .accessibilityLabel("Context usage percentage")
            }
        }
    }

    // MARK: - Token Budget Bar

    private func tokenBudgetBar(_ prompt: AssembledPrompt) -> some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(height: 20)

                // Colored segments for each slot
                HStack(spacing: 0) {
                    ForEach(prompt.orderedSlots) { slot in
                        let slotRatio = contextSize > 0
                            ? Double(slot.tokenCount) / Double(contextSize)
                            : 0
                        let segmentWidth = totalWidth * slotRatio

                        if segmentWidth >= 1 {
                            Rectangle()
                                .fill(colorForSlot(slot.id))
                                .frame(width: segmentWidth, height: 20)
                        }
                    }

                    // History segment (messages not in orderedSlots)
                    let slotTokens = prompt.orderedSlots.reduce(0) { $0 + $1.tokenCount }
                    let historyTokens = prompt.totalTokens - slotTokens
                    if historyTokens > 0 {
                        let historyRatio = Double(historyTokens) / Double(contextSize)
                        let historyWidth = totalWidth * historyRatio
                        if historyWidth >= 1 {
                            Rectangle()
                                .fill(colorForSlot("history"))
                                .frame(width: historyWidth, height: 20)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token budget bar showing slot usage")
        .accessibilityValue("\(assembledPrompt?.totalTokens ?? 0) of \(contextSize) tokens used")
    }

    // MARK: - Slot Row

    private func slotRow(_ slot: ResolvedSlot) -> some View {
        let isExpanded = expandedSlots.contains(slot.id)

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedSlots.remove(slot.id)
                    } else {
                        expandedSlots.insert(slot.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    // Color indicator dot
                    Circle()
                        .fill(colorForSlot(slot.id))
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)

                    // Slot label
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.label)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(slot.position.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Token count
                    Text("\(slot.tokenCount) tokens")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    // Chevron
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(slot.label), \(slot.position.displayName), \(slot.tokenCount) tokens")
            .accessibilityHint(isExpanded ? "Tap to collapse content" : "Tap to expand content")

            // Expanded content
            if isExpanded {
                Text(slot.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Slot content: \(slot.content)")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Color Mapping

    /// Maps a slot ID to a display color.
    static func colorForSlot(_ slotID: String) -> Color {
        switch slotID {
        case "system":
            return .blue
        case "history":
            return .gray
        case "authorsNote":
            return .orange
        case "charDef":
            return .purple
        default:
            if slotID == "lorebook" || slotID.hasPrefix("lorebook_") {
                return .green
            }
            return .secondary
        }
    }

    private func colorForSlot(_ slotID: String) -> Color {
        Self.colorForSlot(slotID)
    }
}

// MARK: - Sample Data

extension PromptInspectorView {

    /// Builds realistic sample data for previewing the inspector UI.
    public static var samplePrompt: AssembledPrompt {
        let slots: [ResolvedSlot] = [
            ResolvedSlot(
                id: "system",
                label: "System Prompt",
                content: "You are a helpful assistant. Respond clearly and concisely. Follow the user's instructions carefully.",
                tokenCount: 24,
                position: .systemPreamble
            ),
            ResolvedSlot(
                id: "charDef",
                label: "Character Definition",
                content: "Name: Aria\nPersonality: Warm, knowledgeable, slightly witty. Speaks in complete sentences.\nScenario: Aria is a librarian at a magical library that contains books from every timeline.",
                tokenCount: 48,
                position: .contextSetup
            ),
            ResolvedSlot(
                id: "lorebook_ancient_library",
                label: "Lorebook: Ancient Library",
                content: "The Ancient Library of Thessalonica was built in the 3rd century and contains scrolls that rewrite themselves based on the reader's intent.",
                tokenCount: 32,
                position: .atDepth(1)
            ),
            ResolvedSlot(
                id: "lorebook_magic_system",
                label: "Lorebook: Magic System",
                content: "Magic in this world is powered by resonance — the ability to harmonize one's intent with the ambient flow of arcane energy.",
                tokenCount: 28,
                position: .atDepth(1)
            ),
            ResolvedSlot(
                id: "authorsNote",
                label: "Author's Note",
                content: "[Write in a descriptive, literary style. Focus on sensory details and character emotions.]",
                tokenCount: 18,
                position: .atDepth(4)
            ),
        ]

        let messages: [(role: String, content: String)] = [
            (role: "user", content: "Tell me about the library."),
            (role: "assistant", content: "The Ancient Library of Thessalonica rises from the mist like a monument to forgotten knowledge. Its shelves stretch endlessly, filled with scrolls that shimmer faintly as you approach."),
            (role: "user", content: "What happens if I pick up a scroll?"),
            (role: "assistant", content: "As your fingers brush the parchment, the text begins to shift and rearrange itself, forming words tailored to your deepest curiosity."),
            (role: "user", content: "I want to learn about the magic system."),
        ]

        let historyTokens = 156
        let slotTokens = slots.reduce(0) { $0 + $1.tokenCount }
        let totalTokens = slotTokens + historyTokens

        var breakdown: [String: Int] = [:]
        for slot in slots {
            breakdown[slot.id] = slot.tokenCount
        }
        breakdown["history"] = historyTokens

        return AssembledPrompt(
            orderedSlots: slots,
            messages: messages,
            totalTokens: totalTokens,
            budgetBreakdown: breakdown
        )
    }
}

// MARK: - Preview

#Preview("Prompt Inspector") {
    PromptInspectorView(
        assembledPrompt: PromptInspectorView.samplePrompt,
        contextSize: 4096
    )
}

#Preview("No Data") {
    PromptInspectorView(
        assembledPrompt: nil,
        contextSize: 4096
    )
}
