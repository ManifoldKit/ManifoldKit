import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// A single row in the session list showing the chat title and relative timestamp.
public struct SessionRowView: View {

    public let session: ChatSession

    public init(session: ChatSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.headline)
                .lineLimit(1)

            Text(session.updatedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), updated \(session.updatedAt, style: .relative) ago")
        .accessibilityIdentifier("session-row")
    }
}

#Preview("Recent Session") {
    SessionRowView(session: ChatSession(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        title: "Travel Planning",
        createdAt: Date(),
        updatedAt: Date()
    ))
}

#Preview("Long Title") {
    SessionRowView(session: ChatSession(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        title: "This is a really long chat title that should be truncated in the row view",
        createdAt: Date(timeIntervalSinceNow: -86400 * 30),
        updatedAt: Date(timeIntervalSinceNow: -86400 * 7)
    ))
}
