import SwiftUI

/// The inputs handed to a ``SessionRowStyle`` when it draws one sidebar row's
/// content.
///
/// Per spec §2 ("Sidebar" row), the row's *selection* and vibrancy are system
/// chrome — `SessionListView` drives them via `List(selection:)`, deferring to
/// the platform. `SessionRowStyle` styles row **content** only: title,
/// snippet, and the quiet pin/selection cues (spec §6's "pinned rows marked
/// quietly").
public struct SessionRowConfiguration {

    /// The session's title.
    public let title: String

    /// A secondary preview line. `nil` reproduces today's `SessionRowView`,
    /// which has no message-snippet feature — a future tranche can populate
    /// this from the session's last message without touching this protocol.
    public let snippet: String?

    /// When the session was last updated. The built-in style renders this as
    /// a live-updating relative-time caption (`Text(_:style:.relative)`),
    /// matching today's `SessionRowView` exactly — kept as a `Date`, not a
    /// pre-formatted `String`, so that live-update behavior survives.
    public let updatedAt: Date

    /// `true` when the session is pinned (spec §6: "pinned rows marked quietly").
    public let isPinned: Bool

    /// `true` when this row is the active/selected session. Informational
    /// only — the system already draws the selection highlight (spec §2); a
    /// custom style may use this for an additional quiet cue (e.g. an accent
    /// dot) but must not attempt to redraw the platform's own selection chrome.
    public let isSelected: Bool

    public init(title: String, snippet: String?, updatedAt: Date, isPinned: Bool, isSelected: Bool) {
        self.title = title
        self.snippet = snippet
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isSelected = isSelected
    }
}

/// A type that draws a sidebar session row's content.
///
/// Follows the same recipe as ``MessageBubbleStyle``: implement
/// ``makeBody(configuration:)``, install with `.sessionRowStyle(_:)`, read
/// `@Environment` from inside the returned `Body`.
public protocol SessionRowStyle: Sendable {
    associatedtype Body: View
    typealias Configuration = SessionRowConfiguration

    @MainActor @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

// MARK: - Built-in styles

/// The default style: reproduces ``SessionRowView``'s historical chrome —
/// title (`.headline`) over a relative-time caption (`.caption`,
/// `.secondary`) — byte-for-byte. Ignores ``SessionRowConfiguration/snippet``,
/// ``SessionRowConfiguration/isPinned``, and ``SessionRowConfiguration/isSelected``
/// entirely, matching today's view having no such affordances. This is the
/// style that becomes the `.classic` preset in Unit 2 §L5.
public struct PlainSessionRowStyle: SessionRowStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(configuration.title)
                .font(.headline)
                .lineLimit(1)

            Text(configuration.updatedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A **new-look** style adding a quiet pin glyph and snippet line (spec §6).
/// Not the default in this tranche — Unit 2 §L5 flips the built-in default.
public struct QuietSessionRowStyle: SessionRowStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        QuietSessionRowBody(configuration: configuration)
    }
}

private struct QuietSessionRowBody: View {
    let configuration: SessionRowConfiguration

    @Environment(\.manifoldTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(configuration.title)
                    .font(theme.type.body.weight(.semibold))
                    .lineLimit(1)
                if configuration.isPinned {
                    Image(systemName: "pin.fill")
                        .font(theme.type.caption2)
                        .foregroundStyle(theme.ink3)
                        .accessibilityLabel("Pinned")
                }
            }
            if let snippet = configuration.snippet {
                Text(snippet)
                    .font(theme.type.caption)
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
            }
            Text(configuration.updatedAt, style: .relative)
                .font(theme.type.caption2)
                .foregroundStyle(theme.ink3)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Static accessors

public extension SessionRowStyle where Self == PlainSessionRowStyle {
    /// The default theme-driven session row. `.sessionRowStyle(.plain)`.
    static var plain: PlainSessionRowStyle { .init() }
}

public extension SessionRowStyle where Self == QuietSessionRowStyle {
    /// The 2026 refresh's session row (quiet pin glyph + snippet). `.sessionRowStyle(.quiet)`.
    static var quiet: QuietSessionRowStyle { .init() }
}

// MARK: - Environment injection

public extension EnvironmentValues {
    /// The active session-row style. Defaults to ``PlainSessionRowStyle`` so
    /// untouched views keep the historical look.
    @Entry var sessionRowStyle: any SessionRowStyle = PlainSessionRowStyle()
}

public extension View {
    /// Sets the ``SessionRowStyle`` for sidebar rows in this view and below.
    ///
    /// ```swift
    /// SessionListView()
    ///     .sessionRowStyle(.quiet)
    /// ```
    func sessionRowStyle<S: SessionRowStyle>(_ style: S) -> some View {
        environment(\.sessionRowStyle, style)
    }
}

// MARK: - Resolution

/// Applies an existential ``SessionRowStyle`` to a configuration. See
/// ``ResolvedMessageBubble``'s doc comment for the type-erasure rationale.
struct ResolvedSessionRow: View {
    let style: any SessionRowStyle
    let configuration: SessionRowConfiguration

    var body: some View {
        AnyView(style.makeBody(configuration: configuration))
    }
}
