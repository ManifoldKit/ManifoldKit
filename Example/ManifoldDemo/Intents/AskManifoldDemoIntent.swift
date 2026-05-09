import AppIntents
import Foundation
import ManifoldInference
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// App Intent that routes a prompt from Spotlight, Siri, or Shortcuts
/// into a fresh chat session inside the demo app.
///
/// ## How it works
///
/// 1. The intent writes a JSON-encoded payload into the shared App Group
///    `UserDefaults` (`group.com.manifoldkit.demo`, key `bck.inbound`).
/// 2. It then opens the app via the `manifolddemo://ingest` URL scheme.
/// 3. The app's `.onOpenURL` handler reads the payload back out and
///    calls ``ChatViewModel/ingest(_:)`` directly, or buffers it via
///    ``PendingPayloadBuffer`` if the persistence container hasn't
///    finished wiring yet.
///
/// The intent lives in the main app target — App Intents on iOS 17+ and
/// macOS 14+ are discovered at runtime via ``AppShortcutsProvider`` and
/// do not require a separate extension target.
public struct AskManifoldDemoIntent: AppIntent {

    public static let title: LocalizedStringResource = "Ask Manifold Demo"

    public static let description = IntentDescription(
        "Sends a prompt to Manifold Demo and opens the app with a fresh chat session.",
        categoryName: "Chat"
    )

    /// Route the result through the app's foreground scene so the user
    /// lands in the chat session the prompt seeded.
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "Prompt", description: "What would you like to ask Manifold Demo?")
    public var prompt: String

    public init() {}

    public init(prompt: String) {
        self.prompt = prompt
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        // Serialize to App Group storage so the main app can retrieve the
        // payload after the scheme-deep-link hits. The envelope carries
        // both the prompt and the attachments array so that future
        // intents (or Share / Action Extensions on #440 / #441) can
        // propagate `MessagePart` payloads (images, files, tool results)
        // end-to-end on the same code path. `MessagePart` is `Codable`,
        // so we round-trip attachments verbatim rather than introducing
        // a wire-format-specific shape.
        //
        // The `prompt`-only intent shipped here keeps `attachments`
        // empty; the envelope contract is in place so a follow-up
        // surface that produces attachments doesn't need a second
        // App Group key.
        let envelope = InboundPayloadEnvelope(
            prompt: prompt,
            attachments: [],
            source: "appIntent"
        )
        if let defaults = UserDefaults(suiteName: DemoAppGroup.identifier) {
            if let encoded = try? JSONEncoder().encode(envelope) {
                defaults.set(encoded, forKey: DemoAppGroup.inboundKey)
            }
        }

        // Open via the custom URL scheme. The app's `.onOpenURL` handler
        // is responsible for actually draining the App Group defaults —
        // this intent only signals that a payload is waiting.
        //
        // The `manifolddemo` scheme is registered in the demo's
        // `Info.plist` via the `CFBundleURLTypes` key, merged into the
        // auto-generated plist. The merge is driven by setting both
        // `GENERATE_INFOPLIST_FILE = YES` and `INFOPLIST_FILE =
        // ManifoldDemo/Info.plist` in the target's build settings —
        // Xcode unions the two so scene-manifest auto-generation keeps
        // working alongside the explicit URL types.
        let url = URL(string: "manifolddemo://ingest")!
        #if canImport(UIKit)
        await UIApplication.shared.open(url, options: [:])
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif

        return .result()
    }
}

// `InboundPayloadEnvelope` and `DemoAppGroup` live in
// `InboundPayloadEnvelope.swift` so the UITest target can compile the
// envelope's wire-format contract test without pulling the rest of
// this file (which depends on `AppIntents`/`UIKit`/`AppKit`).
