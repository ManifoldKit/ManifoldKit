import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// A single row in the session list showing the chat title and relative timestamp.
///
/// Wraps the resolved ``SessionRowStyle`` (spec §8) for its content — the
/// default style reproduces this exact chrome, so untouched hosts see no
/// change. `isSelected` defaults to `false`: `SessionListView`'s `List(selection:)`
/// drives the actual system selection highlight (spec §2); a host that wants
/// the row content to react to selection can pass it explicitly.
public struct SessionRowView: View {

    public let session: ChatSession
    public let isSelected: Bool

    @Environment(\.sessionRowStyle) private var style

    public init(session: ChatSession, isSelected: Bool = false) {
        self.session = session
        self.isSelected = isSelected
    }

    public var body: some View {
        ResolvedSessionRow(
            style: style,
            configuration: SessionRowConfiguration(
                title: session.title,
                snippet: nil,
                updatedAt: session.updatedAt,
                isPinned: session.isPinned,
                isSelected: isSelected
            )
        )
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
