import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// The inputs handed to a per-part renderer closure, plus an escape hatch
/// back to the framework's built-in rendering for that part.
///
/// This is ``ChatMessageRenderer``'s finer-grained sibling (issue #1640,
/// noted as deferred at the top of `ChatMessageRenderer.swift`): where
/// `ChatMessageRenderer` lets a host take over an entire message, this seam
/// lets a host take over one *kind* of content part (a specific tool call, a
/// generated-media kind, …) while every other part in the same message still
/// renders through `MessagePartsView`'s built-in per-kind views.
///
/// Modeled as an options/params struct rather than positional arguments, same
/// rationale as ``ChatMessageRenderParameters``: new fields can be added
/// later without breaking existing renderer closures.
@MainActor
public struct ChatMessagePartRenderParameters {

    /// The part to render.
    public let part: MessagePart

    /// The role of the message this part belongs to — parts render
    /// differently for `.user` vs `.assistant` (e.g. text markdown vs. plain).
    public let role: MessageRole

    /// `true` while the parent message is the actively-streaming assistant turn.
    public let isStreaming: Bool

    // The default-view builder is threaded in by the call site so it can
    // close over whatever per-part collaborators it already has (tool
    // approval state, citations, …) without this params struct needing to
    // know their shapes.
    private let defaultViewBuilder: () -> AnyView

    public init(
        part: MessagePart,
        role: MessageRole,
        isStreaming: Bool,
        defaultView: @escaping () -> AnyView
    ) {
        self.part = part
        self.role = role
        self.isStreaming = isStreaming
        self.defaultViewBuilder = defaultView
    }

    /// The framework's built-in view for this part. Call this for parts your
    /// closure does not handle so they render exactly as they would by default.
    public func defaultPartView() -> AnyView {
        defaultViewBuilder()
    }
}

/// A per-part renderer. Return a custom view for the part kinds you want to
/// take over, or `parameters.defaultPartView()` to defer to the framework.
public typealias ChatMessagePartRenderer =
    @MainActor @Sendable (ChatMessagePartRenderParameters) -> AnyView

// MARK: - Environment injection

public extension EnvironmentValues {
    /// The active per-part renderer, or `nil` to always use the built-in
    /// per-kind view. Injected with `.chatMessagePartRenderer(_:)`.
    ///
    /// Cascades like every other style/renderer slot in this file: the
    /// nearest ancestor's `.chatMessagePartRenderer(_:)` wins (SwiftUI
    /// environment values are last-write-wins along a branch — the same
    /// "LAST-WINS" contract ``chatMessageRenderer`` already has).
    @Entry var chatMessagePartRenderer: ChatMessagePartRenderer?
}

public extension View {
    /// Installs a per-content-part renderer for message parts in this view and
    /// below.
    ///
    /// The lightweight, finer-grained sibling of `.chatMessageRenderer(_:)`:
    /// override only the part kinds you care about (e.g. a specific tool
    /// call) and fall through to the default for everything else — including
    /// every other part in the *same* message.
    ///
    /// ```swift
    /// ChatView(showModelManagement: $show)
    ///     .chatMessagePartRenderer { params in
    ///         if case .toolCall(let call) = params.part, call.toolName == "get_weather" {
    ///             AnyView(WeatherCard(call: call))
    ///         } else {
    ///             params.defaultPartView()
    ///         }
    ///     }
    /// ```
    ///
    /// - Note: The seam is defined here; threading it into
    ///   `MessagePartsView`'s per-kind dispatch (so it actually intercepts
    ///   live message rendering) is tracked separately alongside the rest of
    ///   `MessagePartsView`'s Unit 2 work (issue #1640) — this modifier is
    ///   ready for that call site to consume, mirroring exactly how
    ///   `.chatMessageRenderer(_:)` is consumed by `ChatHistoryView`.
    func chatMessagePartRenderer(_ renderer: @escaping ChatMessagePartRenderer) -> some View {
        environment(\.chatMessagePartRenderer, renderer)
    }
}
