import SwiftUI

/// Animated typing indicator shown while waiting for the first token from the backend.
public struct TypingIndicatorView: View {
    @State private var animationPhase: Int = 0

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(animationPhase == index ? 1.3 : 0.7)
                    .opacity(animationPhase == index ? 1.0 : 0.4)
                    .animation(.easeInOut(duration: 0.4), value: animationPhase)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                animationPhase = (animationPhase + 1) % 3
            }
        }
        .accessibilityLabel("Generating response")
    }
}

#Preview("Typing Indicator") {
    TypingIndicatorView()
}
