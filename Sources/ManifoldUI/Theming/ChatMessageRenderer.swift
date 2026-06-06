import SwiftUI
import ManifoldInference

/// The inputs handed to a per-message renderer closure, plus an escape hatch
/// back to the built-in bubble.
///
/// The key affordance is ``defaultMessageView()``: a consumer can intercept the
/// few messages it cares about (e.g. tool-call records) and fall through to the
/// framework renderer for everything else — avoiding the all-or-nothing cliff of
/// a full BYO-UI message list. Modeled as an options/params struct (not loose
/// positional arguments) so new fields can be added without breaking call sites.
@MainActor
public struct ChatMessageRenderParameters {

    /// The record to render.
    public let message: ChatMessageRecord

    /// `true` while this message is the actively-streaming assistant turn.
    public let isStreaming: Bool

    /// `true` when the message is pinned (preserved across context trimming).
    public let isPinned: Bool

    // Internal collaborators threaded into the default renderer. Kept
    // non-public: a consumer reaches them only indirectly via
    // `defaultMessageView()`, which keeps the surface additive.
    let session: ChatSessionRecord?
    let linkPreviewProvider: LinkPreviewProvider?
    let customKindRenderer: ((ChatMessageRecord) -> AnyView)?

    init(
        message: ChatMessageRecord,
        isStreaming: Bool,
        isPinned: Bool,
        session: ChatSessionRecord?,
        linkPreviewProvider: LinkPreviewProvider?,
        customKindRenderer: ((ChatMessageRecord) -> AnyView)?
    ) {
        self.message = message
        self.isStreaming = isStreaming
        self.isPinned = isPinned
        self.session = session
        self.linkPreviewProvider = linkPreviewProvider
        self.customKindRenderer = customKindRenderer
    }

    /// The framework's built-in bubble for this message, honoring the active
    /// ``ChatTheme`` and ``MessageBubbleStyle``. Call this for messages your
    /// closure does not handle so they render exactly as they would by default.
    public func defaultMessageView() -> AnyView {
        AnyView(
            MessageBubbleView(
                message: message,
                isStreaming: isStreaming,
                isPinned: isPinned,
                linkPreviewProvider: linkPreviewProvider,
                customKindRenderer: customKindRenderer,
                session: session
            )
        )
    }
}

/// A per-message renderer. Return a custom view for messages you want to take
/// over, or `parameters.defaultMessageView()` to defer to the framework.
public typealias ChatMessageRenderer =
    @MainActor @Sendable (ChatMessageRenderParameters) -> AnyView

// MARK: - Environment injection

public extension EnvironmentValues {
    /// The active per-message renderer, or `nil` to always use the built-in
    /// bubble. Injected with `.chatMessageRenderer(_:)`.
    @Entry var chatMessageRenderer: ChatMessageRenderer?
}

public extension View {
    /// Installs a per-message renderer for chat bubbles in this view and below.
    ///
    /// This is the lightweight alternative to forking the message list for
    /// BYO-UI: override only the messages you care about and fall through to the
    /// default for the rest.
    ///
    /// ```swift
    /// ChatView(showModelManagement: $show)
    ///     .chatMessageRenderer { params in
    ///         if params.message.kind == .toolResult {
    ///             AnyView(MyToolCard(message: params.message))
    ///         } else {
    ///             params.defaultMessageView()
    ///         }
    ///     }
    /// ```
    ///
    /// - Note: A per-content-part hook (text / tool-call / thinking blocks) is
    ///   not yet exposed; threading it through `MessagePartsView` is tracked by
    ///   `// TODO(#1640)` and intentionally deferred to keep this change bounded.
    func chatMessageRenderer(_ renderer: @escaping ChatMessageRenderer) -> some View {
        environment(\.chatMessageRenderer, renderer)
    }
}
