import SwiftUI
import ManifoldRuntime

// MARK: - EventTimelineView

/// P5a: Live event timeline — scrolling list of ``ArchitectEventEntry`` values
/// captured from the conversation runtime.
///
/// Each row shows the event kind in monospace, a secondary summary, and a
/// colour-coded dot by category. Compression events receive a distinct
/// background tint and a "COMPRESSION" badge so the "context collapses" moment
/// is immediately visible in the stream.
struct EventTimelineView: View {

    let viewModel: ArchitectViewModel

    @State private var lastEntryID: UUID?

    var body: some View {
        Group {
            if viewModel.eventLog.isEmpty {
                emptyState
            } else {
                eventList
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Events Captured", systemImage: "waveform.slash")
        } description: {
            Text("Tap Record to start capturing runtime events.")
        }
    }

    // MARK: - Event List

    private var eventList: some View {
        ScrollViewReader { proxy in
            List(viewModel.eventLog) { entry in
                EventRowView(entry: entry)
                    .id(entry.id)
                    .listRowBackground(entry.isCompressionRelated ? Color.orange.opacity(0.08) : Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
            }
            .listStyle(.plain)
            .onChange(of: viewModel.eventLog.count) { _, _ in
                if let last = viewModel.eventLog.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - EventRowView

private struct EventRowView: View {

    let entry: ArchitectEventEntry

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Category colour dot
            Circle()
                .fill(categoryColor(for: entry.kind))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.kind.rawValue)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)

                    if entry.isCompressionRelated {
                        Text("COMPRESSION")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.orange)
                    }
                    if entry.isError {
                        Text("ERROR")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.red)
                    }
                }

                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("#\(entry.index)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.kind.rawValue)\(entry.summary.isEmpty ? "" : ": \(entry.summary)"), event \(entry.index)")
    }

    // MARK: - Category colour mapping

    private func categoryColor(for kind: ConversationEventKind) -> Color {
        switch kind {
        case .streamStarted, .streamFinished, .tokenEmitted:
            return .green

        case .contextAssembled, .beforeContextAssembly, .historyShaped:
            return .blue

        case .compressionTriggered, .historyCompressed:
            return .orange

        case .errorRaised:
            return .red

        case .toolCallRequested, .toolCallApproved, .toolCallCompleted:
            return .purple

        case .agentHandoff, .skillInvoked, .hookFired:
            return .indigo

        case .thinkingStarted, .thinkingUpdated, .thinkingFinalized:
            return .cyan

        case .messageInserted, .messageRemoved, .messageUpdated,
             .sessionBranched, .tokenUsageRecorded, .loopDetected,
             .sessionTouchFailed, .afterGeneration:
            return .secondary
        }
    }
}
