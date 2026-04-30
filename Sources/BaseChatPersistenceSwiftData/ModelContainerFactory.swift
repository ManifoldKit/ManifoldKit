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
        BaseChatSchemaV3.self
    }

    /// Returns an on-disk `ModelContainer` configured with the current schema.
    ///
    /// - Parameter configurations: Additional `ModelConfiguration` values to
    ///   pass to `ModelContainer`. Defaults to a single default (on-disk) config.
    /// - Returns: A `ModelContainer` using the current schema.
    /// - Throws: If `ModelContainer` initialisation fails.
    public static func makeContainer(
        configurations: [ModelConfiguration] = [ModelConfiguration()]
    ) throws -> ModelContainer {
        let container = try ModelContainer(
            for: Schema(versionedSchema: currentSchema),
            configurations: configurations
        )
        applyFileProtection(to: configurations)
        return container
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
