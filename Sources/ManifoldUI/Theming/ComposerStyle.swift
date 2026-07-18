import SwiftUI
import ManifoldInference

/// Which lifecycle phase the composer is in (spec §3, §8).
///
/// The phase drives the send/stop morph and which accessory band renders
/// above the field; it is data owned by the composer's view model, not the
/// style — the style only ever reads it to decide chrome (Principle 3,
/// "state is data, styling decides").
public enum ComposerPhase: Sendable, Equatable {
    /// No draft text, no attachments, not generating.
    case idle
    /// The user is actively drafting (has text and/or attachments).
    case composing
    /// A turn is in flight — the send affordance morphs to stop.
    case generating
    /// The voice accessory panel is open above the capsule/bar.
    case voice
}

/// The inputs handed to a ``ComposerStyle`` when it draws the composer's
/// chrome (capsule/bar background, shape, padding).
///
/// Mirrors ``MessageBubbleConfiguration``'s split: the style owns only the
/// *container* — the assembled field, "+" menu, and send/stop button are
/// built by `ChatInputBar` and passed in type-erased, so a custom style can
/// restyle the capsule/bar without re-implementing attachment gating, the
/// permission-gated mic, or the quick-action pill strip.
public struct ComposerConfiguration {

    /// The fully-assembled inner composer content (field + affordances),
    /// type-erased so a style does not need to know about attachment gating
    /// or voice wiring.
    public let content: AnyView

    /// The current lifecycle phase. Styles typically use this to switch
    /// container geometry (e.g. a taller accessory band while `.voice`).
    public let phase: ComposerPhase

    /// `true` when the draft-attachment strip has at least one attachment.
    /// Styles may use this to reserve space for the accessory band above the
    /// field without the strip's content leaking into the style layer.
    public let hasAttachments: Bool

    public init(content: AnyView, phase: ComposerPhase, hasAttachments: Bool) {
        self.content = content
        self.phase = phase
        self.hasAttachments = hasAttachments
    }
}

/// A type that draws the chrome around the chat composer.
///
/// Follows the same recipe as ``MessageBubbleStyle``: implement
/// ``makeBody(configuration:)`` to wrap `configuration.content` in your own
/// background/shape/padding, install it with `.composerStyle(_:)`, and read
/// `@Environment` (color scheme, the active ``ManifoldTheme``) from inside the
/// returned `Body` view.
///
/// `Sendable` because the resolved style is carried through the SwiftUI
/// environment.
public protocol ComposerStyle: Sendable {
    associatedtype Body: View
    typealias Configuration = ComposerConfiguration

    /// Produces the styled composer for the given configuration.
    ///
    /// `@MainActor` because composers are only ever built during SwiftUI
    /// render (the configuration carries a non-`Sendable` `AnyView`); the
    /// style type itself stays `Sendable` so it can be carried through the
    /// environment.
    @MainActor @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

// MARK: - Built-in styles

/// The default style: reproduces the framework's historical composer chrome
/// — a rounded-rectangle field background reading `ManifoldTheme.surface` —
/// by reading the active ``ManifoldTheme``. This is what `ChatInputBar`'s
/// existing `.background(.fill.tertiary, in: RoundedRectangle(cornerRadius:
/// 12))` migrates onto; the built-in look does not change.
///
/// This is the style that becomes the `.classic` preset in Unit 2 §L5 — the
/// new-look glass capsule/bar (spec §3) is a distinct, not-yet-default style.
public struct PlainComposerStyle: ComposerStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.content
    }
}

/// A **new-look** style implementing the spec's floating glass capsule (iOS)
/// / docked glass bar (macOS) geometry (spec §3). Not the default in this
/// tranche — Unit 2 §L5 flips the built-in default once the composer
/// redesign (§L3) has wired real "+" menu / send-stop geometry into
/// `configuration.content`. Until then this style only restyles the
/// container; the inner content is whatever `ChatInputBar` currently builds.
public struct GlassComposerStyle: ComposerStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        GlassComposerBody(configuration: configuration)
    }
}

private struct GlassComposerBody: View {
    let configuration: ComposerConfiguration

    @Environment(\.manifoldTheme) private var theme

    var body: some View {
        configuration.content
            .manifoldGlass(theme, in: Capsule(style: .continuous))
    }
}

// MARK: - Static accessors

public extension ComposerStyle where Self == PlainComposerStyle {
    /// The default theme-driven composer chrome. `.composerStyle(.plain)`.
    static var plain: PlainComposerStyle { .init() }
}

public extension ComposerStyle where Self == GlassComposerStyle {
    /// The 2026 refresh's glass capsule/bar. `.composerStyle(.glass)`.
    static var glass: GlassComposerStyle { .init() }
}

// MARK: - Environment injection

public extension EnvironmentValues {
    /// The active composer style. Defaults to ``PlainComposerStyle`` so
    /// untouched views keep the historical look.
    @Entry var composerStyle: any ComposerStyle = PlainComposerStyle()
}

public extension View {
    /// Sets the ``ComposerStyle`` for the chat composer in this view and below.
    ///
    /// Cascades through the environment like `.messageBubbleStyle(_:)`:
    ///
    /// ```swift
    /// ChatView(showModelManagement: $show)
    ///     .composerStyle(.glass)
    /// ```
    func composerStyle<S: ComposerStyle>(_ style: S) -> some View {
        environment(\.composerStyle, style)
    }
}

// MARK: - Resolution

/// Applies an existential ``ComposerStyle`` to a configuration. See
/// ``ResolvedMessageBubble``'s doc comment for the type-erasure rationale —
/// this mirrors it exactly.
struct ResolvedComposer: View {
    let style: any ComposerStyle
    let configuration: ComposerConfiguration

    var body: some View {
        AnyView(style.makeBody(configuration: configuration))
    }
}
