import XCTest
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference

/// Defends the per-app default SwiftData store path derivation in
/// ``ModelContainerFactory/defaultStoreURL()``.
///
/// The bug this guards against: prior to this change, every ManifoldKit
/// consumer that called `ManifoldBootstrap` without overriding
/// `makeModelContainer:` shared a single
/// `<Application Support>/default.store` path. Two BCK-based apps installed
/// on the same machine would clobber each other's SwiftData store and crash
/// the second app to launch via `try!` in `ManifoldBootstrap`'s default
/// container build.
///
/// These tests verify the URL derivation is stable per `bundleIdentifier`
/// and that the legacy fallback path triggers (silently — there's no public
/// hook on the os.Logger output) when the host has not configured one.
@MainActor
final class ModelContainerDefaultStorePathTests: XCTestCase {

    private var originalConfiguration: ManifoldConfiguration!

    override func setUp() {
        super.setUp()
        originalConfiguration = ManifoldConfiguration.shared
    }

    override func tearDown() {
        ManifoldConfiguration.shared = originalConfiguration
        super.tearDown()
    }

    func test_defaultStoreURL_isUnderApplicationSupport_perBundleDirectory() throws {
        let bundleIdentifier = "com.manifoldkit.tests.\(UUID().uuidString)"
        ManifoldConfiguration.shared = ManifoldConfiguration(
            appName: "Default Store Path",
            bundleIdentifier: bundleIdentifier
        )
        defer {
            // Clean up the directory the derivation creates so the test
            // doesn't leave artefacts behind.
            if let url = ModelContainerFactory.defaultStoreURL() {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let url = try XCTUnwrap(ModelContainerFactory.defaultStoreURL())

        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        XCTAssertTrue(
            url.path.hasPrefix(appSupport.path),
            "Derived store URL must live under Application Support — got: \(url.path)"
        )
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, bundleIdentifier,
                       "Default store must live in a per-bundle directory")
        XCTAssertEqual(url.lastPathComponent, "store.sqlite",
                       "Default store filename should be store.sqlite (not the legacy default.store)")
    }

    func test_defaultStoreURL_differsBetweenBundleIdentifiers() throws {
        // The whole point of this fix: two BCK consumers with different bundle
        // identifiers must derive different default store URLs.
        let bundleA = "com.example.appA.\(UUID().uuidString)"
        let bundleB = "com.example.appB.\(UUID().uuidString)"

        ManifoldConfiguration.shared = ManifoldConfiguration(bundleIdentifier: bundleA)
        let urlA = try XCTUnwrap(ModelContainerFactory.defaultStoreURL())

        ManifoldConfiguration.shared = ManifoldConfiguration(bundleIdentifier: bundleB)
        let urlB = try XCTUnwrap(ModelContainerFactory.defaultStoreURL())

        defer {
            try? FileManager.default.removeItem(at: urlA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: urlB.deletingLastPathComponent())
        }

        XCTAssertNotEqual(urlA, urlB,
                          "Distinct bundle identifiers must derive distinct default store URLs")
        XCTAssertEqual(urlA.lastPathComponent, "store.sqlite")
        XCTAssertEqual(urlB.lastPathComponent, "store.sqlite")
    }

    func test_defaultStoreURL_returnsNil_whenBundleIdentifierIsFrameworkDefault() {
        // Hosts that forget to set their own bundle identifier inherit
        // `com.manifoldkit`. Per the new derivation, the factory must NOT
        // invent a per-app path in that case (because two such hosts would
        // still collide). Instead it returns nil so the caller falls back to
        // SwiftData's `ModelConfiguration()` default — the legacy
        // `default.store` path. The behaviour is loud (logged warning) but
        // not a trap.
        ManifoldConfiguration.shared = ManifoldConfiguration()
        XCTAssertEqual(ManifoldConfiguration.shared.bundleIdentifier,
                       ManifoldConfiguration.frameworkDefaultBundleIdentifier)
        XCTAssertNil(ModelContainerFactory.defaultStoreURL(),
                     "Framework-default bundle identifier must fall back to SwiftData's default")
    }

    func test_defaultStoreURL_createsPerBundleDirectoryOnDisk() throws {
        let bundleIdentifier = "com.manifoldkit.tests.directory.\(UUID().uuidString)"
        ManifoldConfiguration.shared = ManifoldConfiguration(bundleIdentifier: bundleIdentifier)

        let url = try XCTUnwrap(ModelContainerFactory.defaultStoreURL())
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            "Per-bundle directory should be created on first derivation"
        )
        XCTAssertTrue(isDirectory.boolValue, "Per-bundle path should be a directory")
    }
}
