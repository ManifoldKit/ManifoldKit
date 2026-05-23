import Foundation
import ManifoldInference

#if canImport(AppIntents)
import AppIntents

// MARK: - AskManifoldHandler

/// Narrow seam between `AskManifoldIntent` and the host's conversation runtime.
///
/// A two-method protocol keeps the intent testable with a mock, lets hosts wire
/// any backing implementation (including `ConversationRuntime`), and means
/// `ManifoldAppIntents` never needs to know about sessions, stores, or
/// persistence plumbing. Adding `ManifoldRuntime` to this target would drag
/// SwiftData into every app that links here — this protocol sidesteps that.
///
/// ## Wiring to `ConversationRuntime`
///
/// ```swift
/// actor RuntimeHandler: AskManifoldHandler {
///     private let runtime: ConversationRuntime
///
///     init(runtime: ConversationRuntime) { self.runtime = runtime }
///
///     func ask(_ prompt: String) async throws -> String {
///         try await runtime.sendAndAwaitReply(prompt)
///     }
///
///     func displayName() async -> String { "My Chat" }
/// }
///
/// await ManifoldIntentConfiguration.shared.configure(handler: RuntimeHandler(runtime: myRuntime))
/// ```
@available(iOS 18, macOS 15, *)
public protocol AskManifoldHandler: Actor {
    /// Send a prompt and return the full assistant reply.
    ///
    /// Called from `AskManifoldIntent.perform()` on a background actor. The
    /// `Actor` constraint satisfies Swift 6 sendability — the intent framework
    /// can call `perform()` on any thread.
    func ask(_ prompt: String) async throws -> String

    /// Short human-readable name surfaced in Siri readback.
    ///
    /// Example: "My App Chat" → Siri says "Here's what My App Chat says: …"
    func displayName() async -> String
}

// MARK: - ManifoldIntentConfiguration

/// Process-global registry that wires a host-supplied ``AskManifoldHandler``
/// to `AskManifoldIntent`.
///
/// Call ``configure(handler:)`` once during startup (typically in `@main` or
/// `AppDelegate.application(_:didFinishLaunchingWithOptions:)`):
///
/// ```swift
/// await ManifoldIntentConfiguration.shared.configure(handler: myHandler)
/// ```
///
/// Thread-safety is serialised through the actor, so it is safe to call from
/// any execution context. Calling ``configure(handler:)`` more than once
/// replaces the previous handler — latest registration wins, which makes it
/// easy to swap handlers during testing.
@available(iOS 18, macOS 15, *)
public actor ManifoldIntentConfiguration {

    public static let shared = ManifoldIntentConfiguration()

    private var _handler: (any AskManifoldHandler)?

    private init() {}

    /// Registers the handler that `AskManifoldIntent` will call.
    public func configure(handler: some AskManifoldHandler) {
        _handler = handler
    }

    /// Returns the registered handler, or `nil` when none has been configured.
    public var handler: (any AskManifoldHandler)? {
        _handler
    }

    /// Removes the registered handler, leaving the configuration in its
    /// initial unconfigured state. Intended for test teardown only.
    func clearHandler() {
        _handler = nil
    }
}

// MARK: - AskManifoldIntent

/// System AppIntent that routes a prompt into the host app's configured
/// ManifoldKit runtime and returns the assistant's reply.
///
/// ## Surfacing in Shortcuts / Siri
///
/// Declare an `AppShortcutsProvider` in your **host bundle** (not in the
/// library) that references this intent:
///
/// ```swift
/// import AppIntents
/// import ManifoldAppIntents
///
/// struct MyAppShortcuts: AppShortcutsProvider {
///     static var appShortcuts: [AppShortcut] {
///         AppShortcut(
///             intent: AskManifoldIntent(),
///             phrases: ["Ask \(.applicationName)"],
///             shortTitle: "Ask",
///             systemImageName: "text.bubble"
///         )
///     }
/// }
/// ```
///
/// The `AppShortcutsProvider` **must live in the host bundle** — the AppIntents
/// build toolchain scans main-bundle and app-extension sources for
/// `.stringsdata` phrase extraction. Framework-only declarations are not
/// indexed at build time. The intent type itself (`AskManifoldIntent`) can be
/// library-declared; only the `AppShortcutsProvider` wrapper needs to be in
/// the host bundle.
///
/// ## Configuration
///
/// Before the intent can run, call:
///
/// ```swift
/// await ManifoldIntentConfiguration.shared.configure(handler: myHandler)
/// ```
///
/// If no handler is configured when the intent fires, it returns a graceful
/// error dialog rather than crashing.
@available(iOS 18, macOS 15, *)
public struct AskManifoldIntent: AppIntent {

    public static let title: LocalizedStringResource = "Ask Manifold"

    public static let description = IntentDescription(
        "Sends a prompt to the Manifold-powered chat and returns the reply.",
        categoryName: "Chat"
    )

    /// Defaults to `false` so Siri can speak the reply in a background context
    /// (e.g. lock screen, CarPlay). Set to `true` in your `AppShortcutsProvider`
    /// shortcut if you want the chat UI to open after the reply.
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Prompt", description: "What would you like to ask?")
    public var prompt: String

    public init() {}

    public init(prompt: String) {
        self.prompt = prompt
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let handler = await ManifoldIntentConfiguration.shared.handler else {
            // Host hasn't called configure(). Return a useful error dialog
            // instead of trapping — the intent framework reads this back
            // through Siri or displays it in Shortcuts.
            return .result(
                dialog: "Manifold is not configured. Open the app and try again."
            )
        }

        do {
            let reply = try await handler.ask(prompt)
            guard !reply.isEmpty else {
                // A conforming handler returned an empty string — surface this
                // as a dialog rather than speaking "\(source) says: " verbatim.
                Log.inference.warning("AskManifoldIntent: handler returned empty reply")
                return .result(dialog: "I didn't get a response. Please try again.")
            }
            let source = await handler.displayName()
            return .result(
                dialog: IntentDialog(stringLiteral: "\(source) says: \(reply)")
            )
        } catch {
            // Surface as a graceful dialog rather than rethrowing — thrown
            // errors in AppIntents show a generic system error sheet, which is
            // worse UX than a spoken message. Log the real error so it's
            // visible in the unified log.
            Log.inference.warning(
                "AskManifoldIntent: handler threw — \(String(describing: error), privacy: .public)"
            )
            return .result(
                dialog: "Something went wrong. Please try again."
            )
        }
    }
}

#endif // canImport(AppIntents)
