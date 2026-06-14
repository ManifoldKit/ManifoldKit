import SwiftUI

/// Animated typing indicator shown while waiting for the first token from the backend.
public struct TypingIndicatorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationPhase: Int = 0

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                let appearance = Self.dotAppearance(reduceMotion: reduceMotion, isActive: animationPhase == index)
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(appearance.scale)
                    .opacity(appearance.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: animationPhase)
            }
        }
        // Honour Reduce Motion: skip the pulsing cycle entirely and render a
        // static three-dot glyph. Keyed on `reduceMotion` so toggling the
        // setting starts/stops the loop without recreating the view.
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                animationPhase = (animationPhase + 1) % 3
            }
        }
        .accessibilityLabel("Generating response")
    }

    /// Per-dot scale/opacity. Under Reduce Motion every dot is uniform (a static
    /// three-dot glyph, no implied movement); otherwise the active dot is enlarged
    /// and fully opaque. Extracted so the reduce-motion fallback is unit-tested
    /// without standing up a SwiftUI host.
    static func dotAppearance(reduceMotion: Bool, isActive: Bool) -> (scale: CGFloat, opacity: Double) {
        if reduceMotion { return (scale: 1.0, opacity: 0.7) }
        return isActive ? (scale: 1.3, opacity: 1.0) : (scale: 0.7, opacity: 0.4)
    }
}

#Preview("Typing Indicator") {
    TypingIndicatorView()
}
