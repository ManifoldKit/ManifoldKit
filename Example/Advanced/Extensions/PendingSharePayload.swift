import Foundation

/// Codable payload written to the App Group container by Share and Action
/// Extensions and drained by the host app on the next foreground transition.
///
/// This type is intentionally **pure Foundation** — no ManifoldKit dependency
/// — so it can be compiled into both the host app and the lightweight
/// extension targets, which must stay under the iOS extension memory budget.
///
/// ## Wire format
///
/// Extensions write a JSON-encoded `PendingSharePayload` to:
/// - App Group: ``DemoSharedAppGroup/identifier``
/// - Key: ``DemoSharedAppGroup/pendingShareKey``
///
/// The host app reads it in ``ManifoldDemoApp/checkForPendingSharePayload()``
/// and converts it to a ``PendingPayload`` before calling
/// ``ChatViewModel/ingestPendingPayload(_:intent:)``.
///
/// ## Payload priority
///
/// If an extension finds multiple item types it queues only one payload per
/// invocation. The exact priority is determined by the producing extension:
/// the Share Extension prefers `URL > text > image`, while the Action
/// Extension prefers `text > URL` (its typical use case is "summarise
/// selection", which is prose-first).
struct PendingSharePayload: Codable, Sendable {

    /// The flavour of content the extension captured.
    enum Kind: String, Codable {
        case text
        case url
        case image
    }

    /// The flavour of content this payload carries.
    var kind: Kind

    /// Plain-text body — populated when `kind == .text`.
    var text: String? = nil

    /// Absolute string of the shared URL — populated when `kind == .url`.
    var urlString: String? = nil

    /// Raw image bytes — populated when `kind == .image`.
    var imageData: Data? = nil

    /// MIME type for `imageData`; defaults to `"image/png"` at the read site
    /// when absent.
    var imageMimeType: String? = nil

    /// Entry point that produced this payload.
    ///
    /// - `"shareExtension"`: iOS/macOS Share sheet
    /// - `"actionExtension"`: iOS Action sheet ("Summarise selection")
    var source: String
}

/// App Group constants shared between the host app and the Share/Action
/// extensions. The host app's `DemoAppGroup` enum re-exports the same
/// identifiers — keep the two in sync (the constants live here so the
/// extension targets, which can't import host-app types, still see them).
enum DemoSharedAppGroup {
    /// App Group identifier — must match the entitlement in
    /// `ManifoldDemo.entitlements`, `ShareExtension.entitlements`, and
    /// `ActionExtension.entitlements`.
    static let identifier = "group.com.manifoldkit.demo"

    /// `UserDefaults` key the extensions write to and the host app drains.
    static let pendingShareKey = "bck.pending-share"
}
