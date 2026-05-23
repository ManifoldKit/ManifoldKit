import AppIntents
import ManifoldAppIntents

/// Surfaces ``AskManifoldDemoIntent`` and ``AskManifoldIntent`` to Spotlight /
/// Siri so users can invoke them by voice or from the keyboard without opening
/// the app first.
///
/// Shortcuts defined here show up automatically when the app is first
/// launched; users can rebind the trigger phrases in the Shortcuts app.
///
/// ## AppShortcutsProvider must live in the host bundle
///
/// The AppIntents build toolchain discovers shortcut phrase metadata at
/// build time by scanning main-bundle and app-extension sources for
/// `.stringsdata` extraction. Framework-only declarations (like
/// `AskManifoldIntent` in `ManifoldAppIntents`) are not indexed — only the
/// `AppShortcutsProvider` wrapper must be in the host bundle.
public struct ManifoldDemoShortcuts: AppShortcutsProvider {

    @available(iOS 18, macOS 15, *)
    public static var appShortcuts: [AppShortcut] {
        // Note: the `prompt` parameter is a plain `String`, which Siri's
        // phrase-binding syntax (`\(\.$prompt)`) does not allow — only
        // `AppEntity` and `AppEnum` parameters can appear inside phrases.
        // Siri will prompt for the text at invocation time instead.
        AppShortcut(
            intent: AskManifoldDemoIntent(),
            phrases: [
                "Ask \(.applicationName)"
            ],
            shortTitle: "Ask Manifold",
            systemImageName: "text.bubble"
        )
        // AskManifoldIntent is the library-provided intent that routes
        // through whatever handler the host wired via
        // ManifoldIntentConfiguration. Exposed alongside the demo-specific
        // intent so integrators can see both patterns side by side.
        AppShortcut(
            intent: AskManifoldIntent(),
            phrases: [
                "Ask \(.applicationName) via Manifold"
            ],
            shortTitle: "Ask via Manifold",
            systemImageName: "text.bubble.fill"
        )
    }
}
