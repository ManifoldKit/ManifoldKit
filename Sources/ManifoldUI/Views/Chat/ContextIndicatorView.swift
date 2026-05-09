import SwiftUI
import ManifoldRuntime

/// Shows context window usage as a compact gauge in the chat toolbar.
///
/// Changes color based on usage: green (< 80%), yellow (80-95%), red (> 95%).
/// Tapping the indicator shows a popover with additional context details.
public struct ContextIndicatorView: View {

    public let usedTokens: Int
    public let maxTokens: Int

    @State private var isPopoverPresented = false

    public init(usedTokens: Int, maxTokens: Int) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
    }

    private var ratio: Double {
        guard maxTokens > 0 else { return 0 }
        return Double(usedTokens) / Double(maxTokens)
    }

    private var color: Color {
        if ratio >= 0.95 { return .red }
        if ratio >= 0.80 { return .yellow }
        return .green
    }

    private var percentage: Int {
        Int(min(ratio * 100, 999))
    }

    public var body: some View {
        HStack(spacing: 4) {
            // Mini progress ring
            ZStack {
                Circle()
                    .stroke(.tertiary, lineWidth: 2)

                Circle()
                    .trim(from: 0, to: min(ratio, 1.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)

            Text("\(percentage)%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(ratio >= 0.80 ? color : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .help("Context: \(usedTokens) / \(maxTokens) tokens (\(percentage)%)")
        .accessibilityLabel("Context used: \(usedTokens) of \(maxTokens) tokens")
        .accessibilityValue("\(percentage) percent")
        .accessibilityHint("Tap for context details")
        .onTapGesture {
            isPopoverPresented = true
        }
        .popover(isPresented: $isPopoverPresented) {
            contextPopover
        }
    }

    // MARK: - Context Popover

    private var contextPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Context Window")
                .font(.headline)

            LabeledContent("Used") {
                Text("\(usedTokens) tokens")
                    .monospacedDigit()
            }

            LabeledContent("Available") {
                Text("\(maxTokens) tokens")
                    .monospacedDigit()
            }

            LabeledContent("Usage") {
                Text("\(percentage)%")
                    .monospacedDigit()
                    .foregroundStyle(color)
            }

            Divider()

            Label("Open Prompt Inspector in Generation Settings for per-slot breakdown.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 240)
    }
}

#Preview("Low usage") {
    ContextIndicatorView(usedTokens: 500, maxTokens: 4096)
}

#Preview("High usage") {
    ContextIndicatorView(usedTokens: 3500, maxTokens: 4096)
}

#Preview("Critical") {
    ContextIndicatorView(usedTokens: 3900, maxTokens: 4096)
}
