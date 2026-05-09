import AppIntents

/// Surfaces ``AskManifoldDemoIntent`` to Spotlight / Siri so users can
/// invoke it by voice or from the keyboard without first opening the app.
///
/// Shortcuts defined here show up automatically when the app is first
/// launched; users can rebind the trigger phrases in the Shortcuts app.
public struct ManifoldDemoShortcuts: AppShortcutsProvider {

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
    }
}
