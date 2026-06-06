import SwiftUI
import ManifoldInference

/// The inputs handed to a ``MessageBubbleStyle`` when it draws one bubble's
/// chrome (background, shape, padding).
///
/// The style owns only the *container* — the inner content (message parts,
/// agent badge, status/timestamp rows, streaming indicators) is built by
/// ``MessageBubbleView`` and passed in type-erased. That split keeps a custom
/// style from having to re-implement the rich bubble internals just to change a
/// background, while still letting it restructure padding/shape per role and
/// streaming state. `Options`-struct shape (rather than positional params) so
/// new fields can be added later without breaking existing styles.
public struct MessageBubbleConfiguration {

    /// The fully-assembled inner bubble content, type-erased so a style does not
    /// need to know about message parts, badges, or timestamps.
    public let content: AnyView

    /// Which side of the conversation this bubble belongs to. Styles typically
    /// switch background and alignment on this.
    public let role: MessageRole

    /// `true` while the assistant is still generating this message. Styles may
    /// use it to soften the look (e.g. a lighter fill) until the turn completes.
    public let isStreaming: Bool

    public init(content: AnyView, role: MessageRole, isStreaming: Bool) {
        self.content = content
        self.role = role
        self.isStreaming = isStreaming
    }
}

/// A type that draws the chrome around a chat message bubble.
///
/// Follows Apple's `ButtonStyle`/`ToggleStyle` recipe: implement
/// ``makeBody(configuration:)`` to wrap `configuration.content` in your own
/// background/shape/padding, install it with `.messageBubbleStyle(_:)`, and read
/// `@Environment` (color scheme, Dynamic Type, the active ``ChatTheme``) from
/// inside the returned `Body` view — which is why `makeBody` returns a `View`
/// rather than drawing directly.
///
/// `Sendable` because the resolved style is carried through the SwiftUI
/// environment.
public protocol MessageBubbleStyle: Sendable {
    associatedtype Body: View
    typealias Configuration = MessageBubbleConfiguration

    /// Produces the styled bubble for the given configuration.
    ///
    /// `@MainActor` because bubbles are only ever built during SwiftUI render
    /// (the configuration carries a non-`Sendable` `AnyView`); the style type
    /// itself stays `Sendable` so it can be carried through the environment.
    @MainActor @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

// MARK: - Built-in styles

/// The default style: reproduces the framework's historical bubble chrome by
/// reading the active ``ChatTheme``. This is what lets Layer 1 (tokens) and
/// Layer 2 (styles) compose — restyle brand colors with `.chatTheme(_:)` and the
/// default style picks them up for free.
public struct PlainMessageBubbleStyle: MessageBubbleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PlainBubbleBody(configuration: configuration)
    }
}

/// Backing view so the theme/Dynamic-Type lookups resolve in a `View` context
/// (the "Resolved-view wrapper" from Apple's styling recipe).
private struct PlainBubbleBody: View {
    let configuration: MessageBubbleConfiguration

    @Environment(\.chatTheme) private var theme
    // Dynamic Type multiplier captured here, at the consumption site, so bubble
    // padding and corner radius grow with the user's text-size setting.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    var body: some View {
        let chrome = theme.chrome(for: configuration.role, scale: typeScale)
        configuration.content
            .padding(chrome.padding)
            .background(
                chrome.background,
                in: RoundedRectangle(cornerRadius: chrome.cornerRadius)
            )
    }
}

/// An iMessage-flavored look: capsule bubbles, accent fill for the user, a
/// hierarchical gray fill for the assistant.
public struct IMessageMessageBubbleStyle: MessageBubbleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        IMessageBubbleBody(configuration: configuration)
    }
}

private struct IMessageBubbleBody: View {
    let configuration: MessageBubbleConfiguration

    @ScaledMetric(relativeTo: .body) private var horizontalPadding: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var verticalPadding: CGFloat = 10

    private var fill: AnyShapeStyle {
        switch configuration.role {
        case .user: AnyShapeStyle(Color.accentColor)
        case .assistant: AnyShapeStyle(.fill.secondary)
        case .system: AnyShapeStyle(Color.clear)
        }
    }

    var body: some View {
        configuration.content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(fill, in: Capsule(style: .continuous))
    }
}

/// A card look: elevated surface, hairline border, and a soft shadow. Reads the
/// active ``ChatTheme`` for corner radius and padding so a host can still tune
/// the metrics with `.chatTheme(_:)`.
public struct CardMessageBubbleStyle: MessageBubbleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        CardBubbleBody(configuration: configuration)
    }
}

private struct CardBubbleBody: View {
    let configuration: MessageBubbleConfiguration

    @Environment(\.chatTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    var body: some View {
        let chrome = theme.chrome(for: configuration.role, scale: typeScale)
        let shape = RoundedRectangle(cornerRadius: chrome.cornerRadius, style: .continuous)
        configuration.content
            .padding(chrome.padding)
            .background(.background, in: shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 1))
            // Fixed-color shadow is acceptable here: it reads identically in
            // light/dark because it is keyed off the bubble's own elevation,
            // not a foreground color the theme controls.
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

// MARK: - Static accessors (Apple's `.bordered`-style call sites)

public extension MessageBubbleStyle where Self == PlainMessageBubbleStyle {
    /// The default theme-driven bubble. `.messageBubbleStyle(.plain)`.
    static var plain: PlainMessageBubbleStyle { .init() }
}

public extension MessageBubbleStyle where Self == IMessageMessageBubbleStyle {
    /// Capsule bubbles in the style of Messages. `.messageBubbleStyle(.iMessage)`.
    static var iMessage: IMessageMessageBubbleStyle { .init() }
}

public extension MessageBubbleStyle where Self == CardMessageBubbleStyle {
    /// Elevated card bubbles. `.messageBubbleStyle(.card)`.
    static var card: CardMessageBubbleStyle { .init() }
}

// MARK: - Environment injection

public extension EnvironmentValues {
    /// The active bubble style. Defaults to ``PlainMessageBubbleStyle`` so
    /// untouched views keep the historical look.
    @Entry var messageBubbleStyle: any MessageBubbleStyle = PlainMessageBubbleStyle()
}

public extension View {
    /// Sets the ``MessageBubbleStyle`` for chat bubbles in this view and below.
    ///
    /// Cascades through the environment like `.buttonStyle(_:)`, so a single call
    /// at the chat root restyles every bubble:
    ///
    /// ```swift
    /// ChatView(showModelManagement: $show)
    ///     .messageBubbleStyle(.iMessage)
    /// ```
    func messageBubbleStyle<S: MessageBubbleStyle>(_ style: S) -> some View {
        environment(\.messageBubbleStyle, style)
    }
}

// MARK: - Resolution

/// Applies an existential ``MessageBubbleStyle`` to a configuration.
///
/// Opening the existential and calling `makeBody` yields an opaque `some View`
/// whose concrete type cannot escape, so it is erased through `AnyView` here —
/// the established type-erasure pattern in this module (see ChatView's
/// `customKindRenderer`). One erasure per bubble container is negligible.
struct ResolvedMessageBubble: View {
    let style: any MessageBubbleStyle
    let configuration: MessageBubbleConfiguration

    var body: some View {
        AnyView(style.makeBody(configuration: configuration))
    }
}
