import SwiftUI
import ManifoldInference

/// The tool-call lifecycle (spec §4, §8) — four typed states:
/// `awaitingApproval → running → completed | failed`, mirroring
/// ``ToolInvocationView/State`` (which stays the framework's concrete,
/// non-style-driven view for consumers who want the built-in shell without
/// theming it further).
public enum ToolInvocationLifecycleState: Sendable, Equatable {
    case awaitingApproval
    case running
    case completed
    case failed
}

/// The inputs handed to a ``ToolInvocationStyle`` when it draws one tool
/// card.
///
/// Carries the typed lifecycle state plus the tool name/args/result/error and
/// the approval closures — everything ``ToolInvocationView`` currently reads
/// directly — so a custom style can fully re-draw the card (chip, spinner,
/// disclosure, retry CTA) without reaching back into `MessagePart`/`ToolCall`
/// shapes.
public struct ToolInvocationConfiguration {

    /// The lifecycle state to render.
    public let state: ToolInvocationLifecycleState

    /// The tool's registered name (e.g. `"get_weather"`).
    public let toolName: String

    /// The raw JSON arguments string, present once the call has been made.
    public let arguments: String?

    /// The tool result's content, present for ``ToolInvocationLifecycleState/completed``
    /// and ``ToolInvocationLifecycleState/failed``.
    public let resultContent: String?

    /// The structured error presentation for a failed result, `nil` for every
    /// other state.
    public let errorPresentation: ToolErrorPresentation?

    /// Invoked when the user approves a pending call. Only meaningful while
    /// ``state`` is ``ToolInvocationLifecycleState/awaitingApproval``.
    public let onApprove: (() -> Void)?

    /// Invoked when the user denies a pending call, with an optional reason.
    /// Only meaningful while ``state`` is ``ToolInvocationLifecycleState/awaitingApproval``.
    public let onDeny: ((String?) -> Void)?

    /// Invoked when the user taps a re-authentication CTA on a failed result
    /// (the MCP reauthenticate hook, spec §4). `nil` when the failure carries
    /// no CTA.
    public let onReauthenticate: ((ToolErrorPresentation.ReauthenticationCTA) -> Void)?

    public init(
        state: ToolInvocationLifecycleState,
        toolName: String,
        arguments: String?,
        resultContent: String?,
        errorPresentation: ToolErrorPresentation?,
        onApprove: (() -> Void)?,
        onDeny: ((String?) -> Void)?,
        onReauthenticate: ((ToolErrorPresentation.ReauthenticationCTA) -> Void)?
    ) {
        self.state = state
        self.toolName = toolName
        self.arguments = arguments
        self.resultContent = resultContent
        self.errorPresentation = errorPresentation
        self.onApprove = onApprove
        self.onDeny = onDeny
        self.onReauthenticate = onReauthenticate
    }
}

/// A type that draws a tool-invocation card.
///
/// Follows the same recipe as ``MessageBubbleStyle``: implement
/// ``makeBody(configuration:)``, install with `.toolInvocationStyle(_:)`, read
/// `@Environment` from inside the returned `Body`.
public protocol ToolInvocationStyle: Sendable {
    associatedtype Body: View
    typealias Configuration = ToolInvocationConfiguration

    @MainActor @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

// MARK: - Built-in styles

/// Reproduces ``ToolInvocationView``'s historical chrome for all four states,
/// byte-for-byte. This is the `.classic` preset since Unit 2 §L5's defaults
/// flip (issue #2307) — ``CardToolInvocationStyle`` is the built-in default now.
public struct PlainToolInvocationStyle: ToolInvocationStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PlainToolInvocationBody(configuration: configuration)
    }
}

private struct PlainToolInvocationBody: View {
    let configuration: ToolInvocationConfiguration

    @Environment(\.manifoldTheme) private var theme

    private func argumentPreview(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(80)) + "…"
    }

    var body: some View {
        switch configuration.state {
        case .awaitingApproval:
            pendingView
        case .running:
            runningView
        case .completed:
            completedView
        case .failed:
            failedView
        }
    }

    private var pendingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
                Text(configuration.toolName)
                    .font(.caption.monospaced())
                    .fontWeight(.semibold)
            }
            Text(argumentPreview(configuration.arguments ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Deny") { configuration.onDeny?(nil) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("approval-deny-button")
                Button("Approve") { configuration.onApprove?() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("approval-approve-button")
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-invocation-pending-\(configuration.toolName)")
    }

    private var runningView: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("calling ")
                .font(.caption)
                .foregroundStyle(.secondary)
            + Text(configuration.toolName)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            + Text("…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .accessibilityIdentifier("tool-invocation-running-\(configuration.toolName)")
    }

    private var completedView: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let arguments = configuration.arguments {
                    Text("Arguments")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(arguments)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let result = configuration.resultContent {
                    Text("Result")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(result)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(theme.statusOKColor)
                Text(configuration.toolName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("tool-invocation-completed-\(configuration.toolName)")
    }

    private var failedView: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let arguments = configuration.arguments {
                    Text("Arguments")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(arguments)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let result = configuration.resultContent, let presentation = configuration.errorPresentation {
                    Text("Error")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(presentation.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(result)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let cta = configuration.errorPresentation?.reauthenticationCTA {
                    Button(cta.message) {
                        configuration.onReauthenticate?(cta)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("tool-error-reauth-button")
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(configuration.toolName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let presentation = configuration.errorPresentation {
                    Text(presentation.summary)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityIdentifier("tool-invocation-failed-\(configuration.toolName)")
    }
}

/// A **new-look** style implementing the spec's one-card/four-typed-state
/// design (spec §4): live states spin/shimmer, terminal states are static and
/// collapsed, status colors come from ``ManifoldTheme``'s semantic tier
/// instead of the literal `.orange` this tranche's `HardcodedColorAuditTest`
/// migration retires. The built-in default since Unit 2 §L5's defaults flip
/// (issue #2307) — apply `.toolInvocationStyle(.plain)` (or
/// `View.classicManifoldTheme()`) to restore the pre-refresh card.
public struct CardToolInvocationStyle: ToolInvocationStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        CardToolInvocationBody(configuration: configuration)
    }
}

private struct CardToolInvocationBody: View {
    let configuration: ToolInvocationConfiguration

    @Environment(\.manifoldTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                icon
                Text(configuration.toolName)
                    .font(theme.type.caption.monospaced())
                    .foregroundStyle(theme.ink2)
                if configuration.state == .running {
                    ProgressView().controlSize(.mini)
                }
            }

            // Live/actionable states carry real controls, not just chrome —
            // a card that only ever showed an icon would leave tool approval
            // and reauthentication with no affordance once this became the
            // default (Unit 2 §L5, issue #2307). Identifiers/labels match
            // ``PlainToolInvocationStyle``'s exactly so both styles satisfy
            // the same behavioral contract (`ToolInvocationViewTests`).
            if configuration.state == .awaitingApproval {
                HStack(spacing: 8) {
                    Button("Deny") { configuration.onDeny?(nil) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("approval-deny-button")
                    Button("Approve") { configuration.onApprove?() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("approval-approve-button")
                }
            }

            if configuration.state == .failed, let cta = configuration.errorPresentation?.reauthenticationCTA {
                Button(cta.message) {
                    configuration.onReauthenticate?(cta)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("tool-error-reauth-button")
            }
        }
        .padding(8)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.shape.sm, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-invocation-\(accessibilitySuffix)-\(configuration.toolName)")
    }

    private var accessibilitySuffix: String {
        switch configuration.state {
        case .awaitingApproval: "pending"
        case .running: "running"
        case .completed: "completed"
        case .failed: "failed"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch configuration.state {
        case .awaitingApproval:
            Image(systemName: "wrench.and.screwdriver").foregroundStyle(theme.ink2)
        case .running:
            EmptyView()
        case .completed:
            Image(systemName: "checkmark.circle").foregroundStyle(theme.statusOK)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(theme.statusWarn)
        }
    }
}

// MARK: - Static accessors

public extension ToolInvocationStyle where Self == PlainToolInvocationStyle {
    /// The default theme-driven tool card. `.toolInvocationStyle(.plain)`.
    static var plain: PlainToolInvocationStyle { .init() }
}

public extension ToolInvocationStyle where Self == CardToolInvocationStyle {
    /// The 2026 refresh's tool card. `.toolInvocationStyle(.card)`.
    static var card: CardToolInvocationStyle { .init() }
}

// MARK: - Environment injection

public extension EnvironmentValues {
    /// The active tool-invocation style. Defaults to ``CardToolInvocationStyle``
    /// since Unit 2 §L5's defaults flip (issue #2307). Apply
    /// `.toolInvocationStyle(.plain)` (or `View.classicManifoldTheme()`) to
    /// restore the pre-refresh card.
    @Entry var toolInvocationStyle: any ToolInvocationStyle = CardToolInvocationStyle()
}

public extension View {
    /// Sets the ``ToolInvocationStyle`` for tool cards in this view and below.
    ///
    /// ```swift
    /// ChatView(showModelManagement: $show)
    ///     .toolInvocationStyle(.card)
    /// ```
    func toolInvocationStyle<S: ToolInvocationStyle>(_ style: S) -> some View {
        environment(\.toolInvocationStyle, style)
    }
}

// MARK: - Resolution

/// Applies an existential ``ToolInvocationStyle`` to a configuration. See
/// ``ResolvedMessageBubble``'s doc comment for the type-erasure rationale.
struct ResolvedToolInvocation: View {
    let style: any ToolInvocationStyle
    let configuration: ToolInvocationConfiguration

    var body: some View {
        AnyView(style.makeBody(configuration: configuration))
    }
}
