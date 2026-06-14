import SwiftUI

/// Pulsing cursor appended to the end of a streaming message to indicate ongoing generation.
public struct StreamingCursorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = true

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 2, height: 16)
            .opacity(Self.cursorOpacity(reduceMotion: reduceMotion, isVisible: isVisible))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: isVisible)
            .onAppear {
                // Honour Reduce Motion: leave the cursor solid (no pulsing).
                guard !reduceMotion else { return }
                isVisible = false
            }
    }

    /// Cursor opacity. Under Reduce Motion the cursor stays solid (no pulsing);
    /// otherwise it follows the pulsing `isVisible` toggle. Extracted for testing.
    static func cursorOpacity(reduceMotion: Bool, isVisible: Bool) -> Double {
        if reduceMotion { return 1.0 }
        return isVisible ? 1.0 : 0.0
    }
}

#Preview("Streaming Cursor") {
    StreamingCursorView()
}
