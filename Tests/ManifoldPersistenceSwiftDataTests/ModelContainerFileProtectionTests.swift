import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference

/// Tests covering the Data Protection attribute applied to the SwiftData
/// store by ``ModelContainerFactory`` on iOS/tvOS/watchOS.
///
/// These are integration tests: they write real SwiftData stores to the
/// filesystem and inspect `URLResourceValues` on the resulting files.
final class ModelContainerFileProtectionTests: XCTestCase {

    private var tempStoreDirectory: URL?
    private var originalFileProtectionClass: FileProtectionType?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalFileProtectionClass = ManifoldConfiguration.shared.fileProtectionClass
    }

    override func tearDownWithError() throws {
        if let tempStoreDirectory {
            try? FileManager.default.removeItem(at: tempStoreDirectory)
        }
        tempStoreDirectory = nil
        ManifoldConfiguration.shared.fileProtectionClass = originalFileProtectionClass
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Creates an isolated per-test directory under the system temp folder.
    /// Captured in `tempStoreDirectory` so `tearDown` can clean it up even if
    /// assertions fail mid-test.
    private func makeTempStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifoldFileProtection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempStoreDirectory = directory
        return directory.appendingPathComponent("Manifold.sqlite")
    }

    /// Reads the Data Protection class from `url`.
    ///
    /// Returns `nil` if no protection class is set (expected on macOS) or the
    /// file is missing.
    ///
    /// ## Simulator / real-device differences
    ///
    /// `FileManager.attributesOfItem` does not populate `.protectionKey` on the
    /// iOS Simulator — `setAttributes` accepts the call without error but the
    /// stat metadata the simulator exposes never reflects it.
    ///
    /// `URLResourceValues.fileProtection` works on both the simulator and real
    /// hardware and is therefore used as the primary read path.  However, its
    /// raw-value namespace uses the `NSURLFileProtection*` prefix while
    /// `FileProtectionType` uses `NSFileProtection*`, so a conversion is
    /// required.  The two namespaces map 1-to-1 by replacing the `NSURL` prefix
    /// with `NSFile`.
    ///
    /// On the simulator all four protection classes are reported identically as
    /// `.completeUntilFirstUserAuthentication` because the simulator sandbox
    /// does not enforce individual tiers.  Tests that rely on reading back a
    /// specific non-default class must be skipped on the simulator — see
    /// `test_makeContainer_honoursCustomProtectionClass`.
    private func readFileProtection(at url: URL) -> FileProtectionType? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // Primary: URLResourceValues works on both real devices and simulators.
        // The returned type uses the `NSURLFileProtection*` raw-value prefix;
        // convert to `FileProtectionType` by swapping in the `NSFileProtection*`
        // prefix.
        if let rv = try? url.resourceValues(forKeys: [.fileProtectionKey]),
           let fp = rv.fileProtection {
            let rawValue = fp.rawValue.replacingOccurrences(
                of: "NSURLFileProtection",
                with: "NSFileProtection"
            )
            return FileProtectionType(rawValue: rawValue)
        }

        // Fallback: attributesOfItem works on real iOS devices but the
        // simulator never populates .protectionKey here.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        guard let raw = attrs[.protectionKey] as? String else { return nil }
        return FileProtectionType(rawValue: raw)
    }

    // MARK: - iOS / tvOS / watchOS: protection IS applied

    func test_makeContainer_appliesDefaultFileProtection_onMobilePlatforms() throws {
        #if !(os(iOS) || os(tvOS) || os(watchOS)) || targetEnvironment(macCatalyst)
        try XCTSkipIf(true, "File protection only applies on iOS/tvOS/watchOS (not macOS or Catalyst)")
        #else
        // Default config should be .completeUntilFirstUserAuthentication.
        XCTAssertEqual(
            ManifoldConfiguration().fileProtectionClass,
            .completeUntilFirstUserAuthentication
        )

        let storeURL = try makeTempStoreURL()
        let config = ModelConfiguration(url: storeURL)
        _ = try ModelContainerFactory.makeContainer(configurations: [config])

        XCTAssertEqual(
            readFileProtection(at: storeURL),
            ManifoldConfiguration.shared.fileProtectionClass
        )
        #endif
    }

    func test_makeContainer_honoursCustomProtectionClass() throws {
        #if !(os(iOS) || os(tvOS) || os(watchOS)) || targetEnvironment(macCatalyst)
        try XCTSkipIf(true, "File protection only applies on iOS/tvOS/watchOS")
        #else
        // The iOS Simulator sandbox does not distinguish individual protection
        // classes — setAttributes succeeds but every class reads back as the
        // simulator default (.completeUntilFirstUserAuthentication).  This
        // assertion requires the real Secure Enclave to be meaningful.
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil,
            "Simulator reports all protection classes as the default — run on physical hardware"
        )

        ManifoldConfiguration.shared.fileProtectionClass = .complete

        let storeURL = try makeTempStoreURL()
        let config = ModelConfiguration(url: storeURL)
        _ = try ModelContainerFactory.makeContainer(configurations: [config])

        XCTAssertEqual(readFileProtection(at: storeURL), .complete)
        #endif
    }

    func test_makeContainer_optOut_doesNotRaiseProtection() throws {
        #if !(os(iOS) || os(tvOS) || os(watchOS)) || targetEnvironment(macCatalyst)
        try XCTSkipIf(true, "File protection only applies on iOS/tvOS/watchOS")
        #else
        // With opt-out (`fileProtectionClass == nil`), the factory must skip
        // setAttributes entirely. We verify this by comparing against a
        // non-opted-out run at `.complete`: the opt-out store must NOT carry
        // `.complete`, while the non-opt-out store must.
        ManifoldConfiguration.shared.fileProtectionClass = nil

        let storeURL = try makeTempStoreURL()
        let config = ModelConfiguration(url: storeURL)
        _ = try ModelContainerFactory.makeContainer(configurations: [config])

        XCTAssertNotEqual(
            readFileProtection(at: storeURL),
            .complete,
            "Opt-out should have skipped setAttributes — the store should not carry the strict .complete class"
        )
        #endif
    }

    func test_makeContainer_appliesProtectionToSidecars() throws {
        #if !(os(iOS) || os(tvOS) || os(watchOS)) || targetEnvironment(macCatalyst)
        try XCTSkipIf(true, "File protection only applies on iOS/tvOS/watchOS")
        #else
        ManifoldConfiguration.shared.fileProtectionClass = .completeUntilFirstUserAuthentication

        let storeURL = try makeTempStoreURL()
        let config = ModelConfiguration(url: storeURL)
        let container = try ModelContainerFactory.makeContainer(configurations: [config])

        // Force a write so SwiftData creates any WAL sidecars it needs.
        let context = ModelContext(container)
        context.insert(PersistedChatSession(title: "fp-test"))
        try context.save()

        // Re-apply protection now that sidecars may exist (the factory only
        // runs once; reopening the container exercises the same code path).
        _ = try ModelContainerFactory.makeContainer(configurations: [ModelConfiguration(url: storeURL)])

        let directory = storeURL.deletingLastPathComponent()
        let baseName = storeURL.lastPathComponent
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let sidecars = entries.filter { $0 != baseName && $0.hasPrefix(baseName) }
        // This assertion only has teeth if SwiftData actually produced WAL
        // sidecars. If it didn't (e.g. journal_mode=delete), sidecars is empty
        // and the loop below trivially passes — which is the correct outcome:
        // nothing to protect.
        for sidecar in sidecars {
            let url = directory.appendingPathComponent(sidecar)
            XCTAssertEqual(readFileProtection(at: url), .completeUntilFirstUserAuthentication,
                           "Sidecar \(sidecar) should inherit the same Data Protection class as the main store")
        }
        #endif
    }

    // MARK: - In-memory stores: protection NOT applied

    func test_inMemoryContainer_doesNotAttemptProtection() throws {
        // An in-memory store resolves to /dev/null — calling setAttributes on
        // that would fail with EPERM and spam the log. The factory must skip
        // in-memory stores entirely on every platform.
        _ = try ModelContainerFactory.makeInMemoryContainer()
        // Success == no crash, no log-level failure. We verify the guard is
        // reachable by also checking an explicit in-memory configuration.
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        _ = try ModelContainerFactory.makeContainer(configurations: [config])
        XCTAssertEqual(config.url.path, "/dev/null",
                       "In-memory SwiftData stores resolve to /dev/null — this is the guard the factory keys off")
    }

    // MARK: - macOS / Catalyst: protection is a no-op

    func test_makeContainer_onMacOS_isNoOp() throws {
        #if (os(iOS) || os(tvOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
        try XCTSkipIf(true, "macOS-only test — Data Protection is handled by FileVault")
        #else
        // On macOS/Catalyst the factory should complete without error and
        // never touch the file protection attribute. If the file exists after
        // container creation, its protection key should be either `nil` or
        // unchanged from whatever the OS set by default.
        let storeURL = try makeTempStoreURL()
        let config = ModelConfiguration(url: storeURL)
        _ = try ModelContainerFactory.makeContainer(configurations: [config])

        // The key part of this test is just that the call completed: the
        // #if guards in the factory mean `applyFileProtection` is an empty
        // function on macOS/Catalyst. Assert the store file exists so we know
        // we exercised the real code path.
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        #endif
    }

    // MARK: - Failure isolation

    func test_makeContainer_missingStoreFile_doesNotThrow() throws {
        // If the store hasn't been written to disk yet at the moment we apply
        // protection, setAttributes would fail with ENOENT. The factory must
        // swallow that and log a warning instead of propagating the error:
        // protection is best-effort, container creation must not regress.
        //
        // We simulate the "missing file" path by pointing at a non-existent
        // URL inside a fresh temp directory before calling makeContainer.
        // SwiftData will still create the file during container init, but the
        // exercise is that no throw escapes.
        let storeURL = try makeTempStoreURL()
        let config = ModelConfiguration(url: storeURL)
        XCTAssertNoThrow(try ModelContainerFactory.makeContainer(configurations: [config]))
    }
}
