import Foundation
import SwiftData
import BaseChatInference

/// Creates `ModelContainer` instances configured with the current schema.
///
/// Use `ModelContainerFactory` instead of constructing `ModelContainer` by hand.
///
/// ```swift
/// // On-disk store (typical app setup)
/// let container = try ModelContainerFactory.makeContainer()
///
/// // In-memory store (tests, previews, ephemeral sessions)
/// let container = try ModelContainerFactory.makeInMemoryContainer()
/// ```
///
/// On iOS, tvOS, and watchOS the factory applies the Data Protection class
/// configured via ``BaseChatConfiguration/fileProtectionClass`` to the store
/// file (and its SQLite `-shm` / `-wal` sidecars). The default class is
/// `.completeUntilFirstUserAuthentication`, which keeps chat history
/// unreadable until the user first unlocks the device after reboot while
/// still allowing background tasks to read the database. Protection is a
/// no-op on macOS and Mac Catalyst (where at-rest protection is handled by
/// FileVault) and on in-memory stores.
public enum ModelContainerFactory {
    /// The current schema version.
    public static var currentSchema: any VersionedSchema.Type {
        BaseChatSchemaV5.self
    }

    /// Returns an on-disk `ModelContainer` configured with the current schema.
    ///
    /// When `configurations` is omitted, the factory derives a per-app default
    /// store URL from ``BaseChatConfiguration/bundleIdentifier``:
    /// `<Application Support>/<bundleIdentifier>/store.sqlite`. This prevents
    /// two BaseChatKit-based apps installed on the same machine from clobbering
    /// each other's SwiftData store at
    /// `<Application Support>/default.store` — a collision that previously
    /// crashed the second app to launch with a schema-mismatch trap because
    /// `BaseChatBootstrap`'s default container is built via `try!`.
    ///
    /// If the host has not customised ``BaseChatConfiguration/bundleIdentifier``
    /// (still the framework default, `com.basechatkit`), the factory logs a
    /// loud warning and falls back to SwiftData's default URL — the legacy
    /// `default.store` path. Failures stay loud, never silent.
    ///
    /// To override entirely, pass an explicit `ModelConfiguration` with the
    /// store URL of your choice (or call ``makeInMemoryContainer()`` for tests).
    ///
    /// - Parameter configurations: Additional `ModelConfiguration` values to
    ///   pass to `ModelContainer`. When omitted, defaults to a single
    ///   per-app on-disk configuration as described above.
    /// - Returns: A `ModelContainer` using the current schema.
    /// - Throws: If `ModelContainer` initialisation fails.
    public static func makeContainer(
        configurations: [ModelConfiguration] = [defaultModelConfiguration()]
    ) throws -> ModelContainer {
        let container = try ModelContainer(
            for: Schema(versionedSchema: currentSchema),
            migrationPlan: BaseChatMigrationPlan.self,
            configurations: configurations
        )
        applyFileProtection(to: configurations)
        return container
    }

    /// Returns the default on-disk `ModelConfiguration` used by
    /// ``makeContainer(configurations:)`` when no explicit configurations are
    /// supplied.
    ///
    /// The returned configuration points at
    /// `<Application Support>/<bundleIdentifier>/store.sqlite`. The
    /// per-bundle directory is created if missing. If
    /// ``BaseChatConfiguration/bundleIdentifier`` is still the framework
    /// default `com.basechatkit`, or Application Support cannot be located, the
    /// fallback is the SwiftData default URL (the legacy `default.store`
    /// path) — the failure mode is loud (logged warning), not silent.
    public static func defaultModelConfiguration() -> ModelConfiguration {
        guard let storeURL = defaultStoreURL() else {
            return ModelConfiguration()
        }
        return ModelConfiguration(url: storeURL)
    }

    /// The default per-app store URL, or `nil` when the host has not configured
    /// a non-default ``BaseChatConfiguration/bundleIdentifier`` or Application
    /// Support cannot be resolved. Callers fall back to SwiftData's
    /// `ModelConfiguration()` default in either case.
    static func defaultStoreURL() -> URL? {
        let bundleIdentifier = BaseChatConfiguration.shared.bundleIdentifier
        if bundleIdentifier == BaseChatConfiguration.frameworkDefaultBundleIdentifier {
            // We won't silently invent a path for hosts that forgot to set
            // their own bundle identifier — two such apps would still collide.
            // Fall back to SwiftData's default and shout about it: this is a
            // host-configuration bug, not a recoverable runtime condition,
            // but per BaseChatKit's error-handling policy it must not trap.
            Log.persistence.warning(
                "BaseChatConfiguration.shared.bundleIdentifier is still the framework default (\(bundleIdentifier, privacy: .public)). Two apps using this default will collide on a shared SwiftData store. Set BaseChatConfiguration.shared = BaseChatConfiguration(bundleIdentifier: \"com.your-app\") at app launch."
            )
            return nil
        }

        let fileManager = FileManager.default
        let appSupport: URL
        do {
            appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            Log.persistence.warning(
                "Failed to resolve Application Support directory: \(error.localizedDescription). Falling back to SwiftData default store URL."
            )
            return nil
        }

        let storeDirectory = appSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        do {
            try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        } catch {
            Log.persistence.warning(
                "Failed to create per-app SwiftData store directory at \(storeDirectory.path, privacy: .private): \(error.localizedDescription). Falling back to SwiftData default store URL."
            )
            return nil
        }
        return storeDirectory.appendingPathComponent("store.sqlite")
    }

    /// Returns an ephemeral in-memory `ModelContainer` configured with the
    /// current schema.
    ///
    /// Suitable for tests, SwiftUI previews, and any context where data must
    /// not be persisted to disk.
    ///
    /// - Returns: An in-memory `ModelContainer`.
    /// - Throws: If `ModelContainer` initialisation fails.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try makeContainer(configurations: [config])
    }

    // MARK: - File Protection

    /// Applies the configured Data Protection class to each on-disk store
    /// backing `configurations`, including any SQLite `-shm` / `-wal` sidecars
    /// SwiftData may have created alongside the main store file.
    ///
    /// This is a best-effort hardening step: failures are logged and swallowed
    /// because a missing protection attribute should never block container
    /// creation. No-op on macOS / Mac Catalyst and for in-memory stores.
    private static func applyFileProtection(to configurations: [ModelConfiguration]) {
        #if (os(iOS) || os(tvOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
        guard let protection = BaseChatConfiguration.shared.fileProtectionClass else {
            return
        }
        for config in configurations where !isInMemoryStore(config) {
            applyProtection(protection, toStoreAt: config.url)
        }
        #endif
    }

    #if (os(iOS) || os(tvOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
    /// Applies `protection` to `storeURL` plus any sibling files SwiftData may
    /// have created for SQLite WAL journalling (`<name>-shm`, `<name>-wal`).
    private static func applyProtection(
        _ protection: FileProtectionType,
        toStoreAt storeURL: URL
    ) {
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.protectionKey: protection]

        setAttributes(attributes, at: storeURL.path)

        // Sidecars live in the same directory and share the store basename.
        let directory = storeURL.deletingLastPathComponent()
        let baseName = storeURL.lastPathComponent
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for entry in entries where entry != baseName && entry.hasPrefix(baseName) {
            setAttributes(attributes, at: directory.appendingPathComponent(entry).path)
        }
    }

    private static func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        at path: String
    ) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
        } catch {
            Log.persistence.warning(
                "Failed to apply file protection to SwiftData store at \(path, privacy: .private): \(error.localizedDescription)"
            )
        }
    }

    /// Returns `true` if `config` represents an in-memory SwiftData store.
    ///
    /// `ModelConfiguration` doesn't expose `isStoredInMemoryOnly` publicly, but
    /// in-memory configurations resolve `url` to `/dev/null`, which is easy to
    /// detect and never a legitimate on-disk target.
    private static func isInMemoryStore(_ config: ModelConfiguration) -> Bool {
        config.url.path == "/dev/null"
    }
    #endif
}
