import Foundation
import SwiftData
import BaseChatInference

/// One-time boot hooks that bridge SwiftData persistence and the framework's
/// non-persistent services.
///
/// Call the entry points here once at app launch — they are idempotent at the
/// boot-once granularity, but there is no caching; repeated calls do repeated
/// work. Host apps that use ``SwiftDataPersistenceProvider`` get the default
/// hooks wired automatically and should not call these directly.
public enum BaseChatBootstrap {

    /// Removes Keychain items whose owning ``BaseChatSchemaV3/APIEndpoint`` row
    /// no longer exists.
    ///
    /// Orphans accumulate when an endpoint row is deleted while the matching
    /// Keychain delete silently fails, or when rows are wiped directly through
    /// SwiftData without routing through the UI. The reaper compares every
    /// account in the framework's Keychain namespace against the current set of
    /// endpoint IDs and deletes anything that no longer has an owner.
    ///
    /// The sweep is a no-op when
    /// ``BaseChatInference/BaseChatConfiguration/keychainReaperEnabled`` is
    /// `false`. Errors (including Keychain access denial in sandboxed contexts)
    /// are logged and swallowed so a boot hook can never crash the app.
    ///
    /// Fire-and-forget — call once per app boot. Returns the number of items
    /// that were actually reaped, for testing and diagnostics.
    @discardableResult
    @MainActor
    public static func reapOrphanedKeychainItems(in modelContext: ModelContext) -> Int {
        guard BaseChatConfiguration.shared.keychainReaperEnabled else {
            return 0
        }

        let validAccounts: Set<String>
        do {
            let descriptor = FetchDescriptor<BaseChatSchemaV3.APIEndpoint>()
            let endpoints = try modelContext.fetch(descriptor)
            validAccounts = Set(endpoints.map(\.keychainAccount))
        } catch {
            Log.security.warning("BaseChatBootstrap.reapOrphanedKeychainItems: failed to fetch APIEndpoint rows — skipping reap: \(error.localizedDescription)")
            return 0
        }

        return KeychainService.sweep(validAccounts: validAccounts)
    }
}
