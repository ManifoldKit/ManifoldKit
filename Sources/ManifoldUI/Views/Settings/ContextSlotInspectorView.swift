import SwiftUI
import ManifoldRuntime
import ManifoldInference

// MARK: - ContextSlotInspectorView

/// P5b: Context slot inspector and compression visualizer.
///
/// Shows the assembled slots from the most recent `.contextAssembled` event,
/// a token budget bar, and a compression history table from
/// `.historyCompressed` events in the log.
struct ContextSlotInspectorView: View {

    let viewModel: ArchitectViewModel

    var body: some View {
        Group {
            if let contextEvent = viewModel.latestContextEvent {
                contextContent(contextEvent)
            } else {
                noContextView
            }
        }
        .accessibilityIdentifier("architect-context-tab")
    }

    // MARK: - No Data

    private var noContextView: some View {
        ContentUnavailableView {
            Label("No Context Data", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Send a message while recording to capture context assembly.")
        }
    }

    // MARK: - Context Content

    private func contextContent(_ entry: ArchitectEventEntry) -> some View {
        Form {
            if case .contextAssembled(let slots)? = entry.event {
                Section("Token Budget") {
                    SlotBudgetBar(slots: slots)
                        .padding(.vertical, 4)
                }

                Section("Slots (\(slots.count))") {
                    if slots.isEmpty {
                        Text("No slots assembled for this turn.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(slots) { slot in
                            SlotRowView(slot: slot)
                        }
                    }
                }
            }

            if !viewModel.compressionEvents.isEmpty {
                compressionHistorySection
            }
        }
    }

    // MARK: - Compression History

    private var compressionHistorySection: some View {
        Section("Compression History (\(viewModel.compressionEvents.count))") {
            ForEach(viewModel.compressionEvents) { entry in
                HStack {
                    Image(systemName: "arrow.down.right.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.label)
                            .font(.system(.caption, design: .monospaced))
                        if !entry.summary.isEmpty {
                            Text(entry.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Text("#\(entry.index)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(entry.label)\(entry.summary.isEmpty ? "" : ": \(entry.summary)"), event \(entry.index)")
            }
        }
    }
}

// MARK: - SlotBudgetBar

/// Proportional token budget bar using `tokenBudget` values from each slot.
/// When no budgets are set, shows an equal-width segment per enabled slot.
private struct SlotBudgetBar: View {

    let slots: [PromptSlot]

    private var enabledSlots: [PromptSlot] { slots.filter { $0.isEnabled } }

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let budgets = enabledSlots.compactMap { $0.tokenBudget }
            let totalBudget = budgets.reduce(0, +)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(height: 20)

                if totalBudget > 0 {
                    // Budget-proportional segments
                    HStack(spacing: 0) {
                        ForEach(Array(enabledSlots.enumerated()), id: \.offset) { idx, slot in
                            if let budget = slot.tokenBudget, budget > 0 {
                                let ratio = Double(budget) / Double(totalBudget)
                                let segmentWidth = totalWidth * ratio
                                if segmentWidth >= 1 {
                                    Rectangle()
                                        .fill(slotColor(index: idx))
                                        .frame(width: segmentWidth, height: 20)
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if !enabledSlots.isEmpty {
                    // Equal-width segments when no budgets are specified
                    HStack(spacing: 0) {
                        ForEach(Array(enabledSlots.enumerated()), id: \.offset) { idx, _ in
                            Rectangle()
                                .fill(slotColor(index: idx))
                                .frame(width: totalWidth / Double(enabledSlots.count), height: 20)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token budget bar for \(slots.count) slots")
    }

    private func slotColor(index: Int) -> Color {
        let palette: [Color] = [.blue, .purple, .green, .orange, .cyan, .indigo, .mint, .pink]
        return palette[index % palette.count]
    }
}

// MARK: - SlotRowView

private struct SlotRowView: View {

    let slot: PromptSlot
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(slot.label)
                                .font(.body)
                                .foregroundStyle(slot.isEnabled ? .primary : .tertiary)
                            if !slot.isEnabled {
                                Text("disabled")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(slot.position.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let budget = slot.tokenBudget {
                        Text("≤\(budget) tokens")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(slot.label), \(slot.position.displayName)\(slot.tokenBudget.map { ", budget \($0) tokens" } ?? "")")
            .accessibilityHint(isExpanded ? "Tap to collapse" : "Tap to expand content")

            if isExpanded {
                Text(slot.content.isEmpty ? "(empty)" : slot.content)
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
}

