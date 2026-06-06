import CoreSpotlight
import Foundation
import ManifoldInference

/// Indexes chat sessions in Core Spotlight so they appear in system search.
///
/// Host apps call ``index(sessions:domainIdentifier:)`` after loading sessions
/// and whenever the session list changes. Implement
/// ``sessionID(from:domainIdentifier:)`` in your `UIApplicationDelegate` /
/// `AppDelegate` (or SwiftUI `.onContinueUserActivity`) to restore the correct
/// session when the user taps a Spotlight result.
@MainActor
public enum SpotlightIndexer {

    /// The default domain identifier used when the host app does not supply one.
    public static let defaultDomainIdentifier = "com.manifoldkit.sessions"

    /// Index (or re-index) the provided sessions in Core Spotlight.
    ///
    /// Call after sessions load and after the session list changes.
    ///
    /// - Parameters:
    ///   - sessions: The sessions to index.
    ///   - domainIdentifier: A reverse-DNS string that groups all items indexed
    ///     by this app. Defaults to ``defaultDomainIdentifier``; pass your
    ///     host app's bundle identifier for best results.
    public static func index(
        sessions: [ChatSession],
        domainIdentifier: String = defaultDomainIdentifier
    ) {
        var items: [CSSearchableItem] = []
        for session in sessions {
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = session.title.isEmpty ? "New Chat" : session.title
            attrs.contentDescription = "AI conversation"
            attrs.keywords = ["ai", "chat", "conversation"]
            let item = CSSearchableItem(
                uniqueIdentifier: session.id.uuidString,
                domainIdentifier: domainIdentifier,
                attributeSet: attrs
            )
            items.append(item)
        }
        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error { print("Spotlight indexing error: \(error)") }
        }
    }

    /// Remove all indexed sessions for the given domain.
    ///
    /// Call on sign-out or when the user's session data is cleared.
    ///
    /// - Parameter domainIdentifier: Must match the identifier passed to
    ///   ``index(sessions:domainIdentifier:)``. Defaults to
    ///   ``defaultDomainIdentifier``.
    public static func deleteAll(
        domainIdentifier: String = defaultDomainIdentifier
    ) {
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in }
    }

    /// Extracts the session ID from an `NSUserActivity` delivered when the
    /// user opens a Core Spotlight result.
    ///
    /// - Parameter userActivity: The activity passed to your scene/app delegate.
    /// - Returns: The `UUID` of the matching session, or `nil` if the activity
    ///   does not represent a Spotlight session result.
    public static func sessionID(from userActivity: NSUserActivity) -> UUID? {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return nil }
        return UUID(uuidString: id)
    }
}
