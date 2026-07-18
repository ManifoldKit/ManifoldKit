import SwiftUI
import ManifoldInference

/// Semantic styling tokens for the chat surface.
///
/// `ChatTheme` is a thin semantic layer *over* SwiftUI's own resolution
/// machinery — it never replaces it. Colors are stored as `AnyShapeStyle` so a
/// token can be an asset-catalog `Color` (automatic Dark Mode / Increase
/// Contrast), a material, or a hierarchical fill such as `.fill.tertiary`;
/// fonts are stored as text styles (`.body`/`.caption`) so Dynamic Type keeps
/// working; and any metric that should grow with Dynamic Type is multiplied by a
/// `@ScaledMetric` factor at the point of consumption (see ``MessageBubbleView``
/// and ``PlainMessageBubbleStyle``). That keeps the litmus test honest: toggling
/// Dark Mode, max Dynamic Type, or Increase Contrast still moves every value.
///
/// ``ChatTheme/standard`` was the framework's *only* appearance through Unit 1
/// (byte-for-byte reproduction of the pre-theming look, which is what made
/// adopting the theming system a zero-breaking change). **Unit 2 §L5 (issue
/// #2307) flips it**: ``ChatTheme/standard`` now carries the 2026 refresh's
/// bubble look (gradient-from-accent user fill, `shape.lg`-aligned corner
/// radius); the historical values move to ``ChatTheme/classic``, which
/// reproduces them exactly. Apply `.chatTheme(.classic)` (or, for the full
/// restore across every style protocol, `View.classicManifoldTheme()` in
/// `ManifoldTheme.swift`) to keep the pre-refresh bubble appearance.
public struct ChatTheme: Sendable {

    /// Fill behind a user (right-aligned) bubble. Default (post-flip, spec §7):
    /// a linear gradient derived from the resolved `Color.accentColor` — "never
    /// a fixed hue." ``classic`` keeps the pre-refresh solid `Color.accentColor`.
    public var userBubbleBackground: AnyShapeStyle

    /// Fill behind an assistant (left-aligned) bubble. Default: `.fill.tertiary`
    /// — unchanged by the flip (only the user-bubble fill and corner radius move).
    public var assistantBubbleBackground: AnyShapeStyle

    /// Fill behind a system notice. Default: clear — system messages render as
    /// centered italic text with no bubble chrome.
    public var systemBubbleBackground: AnyShapeStyle

    /// Corner radius of user/assistant bubbles. Default (post-flip): `20`,
    /// aligned to ``ManifoldThemeShapeScale/lg`` per spec §1 "concentric
    /// geometry... one shape scale... replacing scattered 4/6/8/12pt
    /// constants." ``classic`` keeps the pre-refresh `16`.
    public var cornerRadius: CGFloat

    /// Internal padding applied inside every bubble. Default: `12`.
    public var bubblePadding: CGFloat

    /// Vertical spacing between stacked rows *inside* a bubble (content vs.
    /// status/timestamp row). Default: `4`.
    public var contentSpacing: CGFloat

    /// Vertical spacing between a bubble and its trailing link-preview card.
    /// Default: `6`.
    public var bubbleStackSpacing: CGFloat

    /// Primary text style for bubble body copy (currently the system notice;
    /// also available to custom ``MessageBubbleStyle`` bodies). Default: `.body`.
    public var bubbleFont: Font

    /// Text style for secondary metadata (timestamps, token counts).
    /// Default: `.caption`.
    public var metadataFont: Font

    /// Creates a theme. Every parameter defaults to the framework's current
    /// (post-flip) value, so `ChatTheme()` (and ``standard``) match the 2026
    /// refresh's look. Callers override only the tokens they care about, e.g.
    /// `ChatTheme(userBubbleBackground: AnyShapeStyle(Color.pink))`.
    public init(
        userBubbleBackground: AnyShapeStyle = AnyShapeStyle(
            LinearGradient(
                colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        ),
        assistantBubbleBackground: AnyShapeStyle = AnyShapeStyle(.fill.tertiary),
        systemBubbleBackground: AnyShapeStyle = AnyShapeStyle(Color.clear),
        cornerRadius: CGFloat = 20,
        bubblePadding: CGFloat = 12,
        contentSpacing: CGFloat = 4,
        bubbleStackSpacing: CGFloat = 6,
        bubbleFont: Font = .body,
        metadataFont: Font = .caption
    ) {
        self.userBubbleBackground = userBubbleBackground
        self.assistantBubbleBackground = assistantBubbleBackground
        self.systemBubbleBackground = systemBubbleBackground
        self.cornerRadius = cornerRadius
        self.bubblePadding = bubblePadding
        self.contentSpacing = contentSpacing
        self.bubbleStackSpacing = bubbleStackSpacing
        self.bubbleFont = bubbleFont
        self.metadataFont = metadataFont
    }

    /// The framework default since Unit 2 §L5 (issue #2307) — the 2026
    /// refresh's bubble look (gradient-from-accent user fill, `20`pt corner
    /// radius). See ``classic`` to restore the pre-refresh appearance
    /// byte-for-byte.
    public static let standard = ChatTheme()

    /// Reproduces the pre-2026-refresh bubble appearance byte-for-byte: solid
    /// `Color.accentColor` user fill, `16`pt corner radius. Every other token
    /// (assistant fill, paddings, fonts) is unchanged by the flip, so this
    /// only overrides the two tokens that moved. Apply via
    /// `.chatTheme(.classic)` or, for the full cross-protocol restore,
    /// `View.classicManifoldTheme()` (`ManifoldTheme.swift`).
    public static let classic = ChatTheme(
        userBubbleBackground: AnyShapeStyle(Color.accentColor),
        cornerRadius: 16
    )

    /// The per-role bubble fill.
    public func background(for role: MessageRole) -> AnyShapeStyle {
        switch role {
        case .user: userBubbleBackground
        case .assistant: assistantBubbleBackground
        case .system: systemBubbleBackground
        }
    }

    /// Resolves the chrome metrics a bubble draws with, folding in the current
    /// Dynamic Type scale factor. Kept as a pure function so the
    /// theme→consumed-value path is unit-testable without standing up a view
    /// (ViewInspector cannot read `ShapeStyle` or `@ScaledMetric` output).
    ///
    /// - Parameter scale: the `@ScaledMetric` Dynamic Type multiplier captured
    ///   at the consumption site (`1` at the default content size category).
    public func chrome(for role: MessageRole, scale: CGFloat) -> ResolvedBubbleChrome {
        ResolvedBubbleChrome(
            cornerRadius: cornerRadius * scale,
            padding: bubblePadding * scale,
            background: background(for: role)
        )
    }
}

/// The resolved, Dynamic-Type-scaled chrome a single bubble renders with.
public struct ResolvedBubbleChrome {
    public let cornerRadius: CGFloat
    public let padding: CGFloat
    public let background: AnyShapeStyle
}

// MARK: - Environment injection

public extension EnvironmentValues {
    /// The active chat theme. Defaults to ``ChatTheme/standard`` so untouched
    /// views render with the historical appearance.
    @Entry var chatTheme: ChatTheme = .standard
}

public extension View {
    /// Applies a ``ChatTheme`` to this view and everything below it, including
    /// content presented in `.sheet`/`.fullScreenCover` from inside the subtree.
    ///
    /// Mirrors the shape of `.tint(_:)`/`.font(_:)`: it writes the theme into the
    /// environment, so the cascade resolves at render time and a single call at
    /// the chat root reaches every bubble, the composer, and indicators.
    ///
    /// ```swift
    /// ChatView(showModelManagement: $show)
    ///     .chatTheme(ChatTheme(userBubbleBackground: AnyShapeStyle(Color.indigo)))
    /// ```
    func chatTheme(_ theme: ChatTheme) -> some View {
        environment(\.chatTheme, theme)
    }
}
