import SwiftUI

public struct WakeWordToast: View {
    private let phrase: String

    public init(phrase: String) {
        self.phrase = phrase
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .imageScale(.large)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Wake word detected")
                    .font(.caption.weight(.semibold))
                Text("“\(phrase)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .padding(.horizontal)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: phrase))
        .accessibilityIdentifier("wake-word-toast")
    }

    public static func accessibilityLabel(for phrase: String) -> String {
        "Wake word detected: \(phrase)"
    }
}
