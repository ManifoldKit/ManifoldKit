import SwiftUI

/// Pulsing cursor appended to the end of a streaming message to indicate ongoing generation.
public struct StreamingCursorView: View {
    @State private var isVisible = true

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 2, height: 16)
            .opacity(isVisible ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: isVisible)
            .onAppear { isVisible = false }
    }
}

#Preview("Streaming Cursor") {
    StreamingCursorView()
}
