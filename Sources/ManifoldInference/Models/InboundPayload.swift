import Foundation

/// A unified handoff envelope for prompts arriving from outside the normal
/// compose bar — deep links, App Intents, Share / Action Extensions, etc.
///
/// `InboundPayload` is the single shape the chat view model drains on
/// ingest, regardless of which entry point produced it. This keeps
/// launch-time wiring symmetric: every inbound source serialises itself
/// into a payload, the app writes it into a pending buffer, and the view
/// model ingests it once persistence is ready.
///
/// ## Forward compatibility
///
/// ``attachments`` carries ``MessagePart`` values so richer inputs
/// (images, files) can ride alongside the prompt without changing the
/// API shape. Today only App Intent and deep-link flows populate this
/// struct; Share Extension support (tracked by #440) and Action Extension
/// support (#441) will reuse the same type when they land.
///
/// The struct is intentionally storage-agnostic. Callers persist it
/// through whatever transport suits the caller — App Group
/// `UserDefaults`, pasteboard JSON, or a file in a shared container —
/// and hand the decoded value to the view model.
public struct InboundPayload: Sendable {

    /// Where this payload originated.
    ///
    /// Used for logging attribution and, when a source needs
    /// source-specific handling (e.g. suppressing the model picker on an
    /// intent-driven launch), for branching in the view model.
    public enum Source: Sendable {

        /// The payload came from a custom URL scheme (`manifolddemo://…`).
        case deepLink

        /// The payload came from an `AppIntent` invocation (Siri, Spotlight,
        /// Shortcuts).
        case appIntent

        /// The payload came from a Share Extension.
        case shareExtension
    }

    /// The prompt text to inject as the next user turn.
    public var prompt: String

    /// Additional parts to accompany the prompt.
    ///
    /// Intended to carry ``MessagePart`` values such as images or tool
    /// results that must arrive together with the prompt. Defaults to an
    /// empty array for text-only payloads.
    public var attachments: [MessagePart]

    /// Where the payload came from.
    public var source: Source

    /// Creates an inbound payload.
    ///
    /// - Parameters:
    ///   - prompt: The prompt text to inject.
    ///   - attachments: Forward-compatible list of additional parts
    ///     (default empty).
    ///   - source: The entry point that produced this payload.
    public init(prompt: String, attachments: [MessagePart] = [], source: Source) {
        self.prompt = prompt
        self.attachments = attachments
        self.source = source
    }
}
