import XCTest
import Foundation

/// Guards against regressions on issue #2416: a test class that writes to the
/// real macOS Keychain under the framework's **default** service namespace
/// (`com.manifoldkit.apikeys`, i.e. it never scopes
/// `ManifoldConfiguration.shared.bundleIdentifier` away from
/// `ManifoldConfiguration.frameworkDefaultBundleIdentifier`) can race any
/// other test — in this target or a sibling one batched into the same
/// `swift test --parallel` invocation — whose own default-configuration
/// bootstrap (`ManifoldBootstrap.build`, `_quickStart`,
/// `InMemoryPersistenceHarness.make()`, …) constructs a
/// `SwiftDataPersistenceProvider` and triggers its unconditional
/// `reapOrphanedKeychainItems` sweep of that same shared namespace.
///
/// ## Background
///
/// `KeychainServiceTests.test_store_updatesExisting` flaked under
/// `swift test --parallel` (#2416). The issue as originally filed blamed
/// `KeychainServiceSweepTests` for wiping the shared namespace — that theory
/// was wrong (that class already scoped itself to a private per-test
/// namespace before #2416 was even filed) and would have sent the next
/// investigator to the wrong file. The real mechanism: `swift test
/// --parallel` runs every test *method* in its own OS process, so
/// `ManifoldConfiguration.shared` can never race between two test methods —
/// but the real Keychain (a single on-disk store reachable identically from
/// every process on the machine) can. Any class using the *default*
/// namespace with only per-*account* uniqueness (`uniqueAccount()`-style
/// helpers) is racing every other default-namespace writer in the batch,
/// not just the one that happened to be caught first.
///
/// ## What this test enforces
///
/// Every `.swift` file under `Tests/` that writes to the Keychain — directly
/// via `KeychainService.store(`, or indirectly via the two production
/// call-throughs that reach it (`APIEndpoint`/`APIEndpointRecord`'s
/// `.setAPIKey(`, and `APIEndpointEditorView.rollbackKeychainKey(`) — must
/// also assign `ManifoldConfiguration.shared` inside an `override func
/// setUp` in the same file, scoping every test method in the class to a
/// private namespace before it can write anything.
///
/// This is a class-shaped rule, not a call-shaped one: `setUp` runs before
/// *every* test method, so scoping there (rather than per-call) is what
/// actually closes the race for the whole class. A file that assigns
/// `ManifoldConfiguration.shared` somewhere else — a helper method, a single
/// test body — does not satisfy this audit, because it leaves every other
/// method in the class still writing to the shared default namespace.
///
/// ## Fixing a violation
///
/// Mirror the pattern in `Tests/ManifoldSecretsTests/KeychainServiceTests.swift`
/// or `KeychainServiceSweepTests.swift`:
///
///     private var originalConfig: ManifoldConfiguration!
///
///     override func setUp() {
///         super.setUp()
///         originalConfig = ManifoldConfiguration.shared
///         var config = ManifoldConfiguration.shared
///         config.bundleIdentifier = "com.manifoldkit.tests.<area>.\(UUID().uuidString)"
///         ManifoldConfiguration.shared = config
///     }
///
///     override func tearDown() {
///         // ... existing cleanup ...
///         ManifoldConfiguration.shared = originalConfig
///         originalConfig = nil
///         super.tearDown()
///     }
///
/// DO NOT add an allowlist to silence this test. An unscoped Keychain-writing
/// class is exactly the latent flake #2416 already cost a wasted CI run over
/// — the whole point of the audit is that one such class is enough to
/// reintroduce it under a future re-shuffle of which suites batch together.
/// (The only excluded file is this audit itself, which mentions the needles
/// purely as inert text — the search strings, the sabotage payloads, and
/// error messages.)
final class KeychainNamespaceIsolationAuditTest: XCTestCase {

    /// Source substrings that indicate a file writes to the Keychain, either
    /// directly or through a production call-through that ends in
    /// `KeychainService.store(...)`. Kept as an explicit, reviewable list
    /// rather than trying to detect every possible call shape — a new
    /// call-through that reaches `KeychainService.store` should add its own
    /// needle here in the same PR that introduces it.
    static let keychainWriteNeedles = [
        "KeychainService.store(",
        ".setAPIKey(",
        "rollbackKeychainKey(",
    ]

    func test_everyKeychainWritingTestClassScopesConfigurationInSetUp() throws {
        let testsURL = try Self.locateTestsDirectory()

        let excludedFileNames: Set<String> = [
            (#filePath as NSString).lastPathComponent,
        ]

        let violations = try Self.violations(testsRoot: testsURL, excludedFileNames: excludedFileNames)

        if !violations.isEmpty {
            let formatted = violations.sorted().map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                The following test files write to the Keychain (directly via
                `KeychainService.store(`, or indirectly via `.setAPIKey(` /
                `rollbackKeychainKey(`) without scoping
                `ManifoldConfiguration.shared` in an `override func setUp` in
                the same file. Each one races every other default-namespace
                Keychain writer batched into the same `swift test --parallel`
                invocation (see issue #2416).

                \(formatted)

                Add the setUp/tearDown scoping pattern documented in this
                file's header — see
                Tests/ManifoldSecretsTests/KeychainServiceTests.swift for a
                worked example.
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `violations(testsRoot:excludedFileNames:)` the audit runs)

    /// Plants three files in a temp tree shaped like `Tests/`: one that
    /// writes to the Keychain with no scoping (must be flagged), one that
    /// writes to the Keychain and scopes correctly in `setUp` (must NOT be
    /// flagged), and one that scopes `ManifoldConfiguration.shared` but
    /// outside `setUp` — e.g. inside a single test body (must still be
    /// flagged, because it doesn't protect the whole class).
    func test_sabotage_detectsUnscopedKeychainWritingClass() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "keychain-namespace-isolation-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("ManifoldSecretsTests", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let unscopedFile = root.appendingPathComponent("UnscopedTests.swift")
        try """
        import XCTest
        final class UnscopedTests: XCTestCase {
            func test_store() throws {
                try KeychainService.store(key: "k", account: "a")
            }
        }
        """.write(to: unscopedFile, atomically: true, encoding: .utf8)

        let scopedFile = root.appendingPathComponent("ScopedTests.swift")
        try """
        import XCTest
        final class ScopedTests: XCTestCase {
            private var originalConfig: ManifoldConfiguration!
            override func setUp() {
                super.setUp()
                originalConfig = ManifoldConfiguration.shared
                var config = ManifoldConfiguration.shared
                config.bundleIdentifier = "com.manifoldkit.tests.scoped.\\(UUID().uuidString)"
                ManifoldConfiguration.shared = config
            }
            override func tearDown() {
                ManifoldConfiguration.shared = originalConfig
                super.tearDown()
            }
            func test_store() throws {
                try KeychainService.store(key: "k", account: "a")
            }
        }
        """.write(to: scopedFile, atomically: true, encoding: .utf8)

        let scopedOutsideSetUpFile = root.appendingPathComponent("ScopedOutsideSetUpTests.swift")
        try """
        import XCTest
        final class ScopedOutsideSetUpTests: XCTestCase {
            override func setUp() {
                super.setUp()
                // Deliberately does NOT scope ManifoldConfiguration here.
            }
            func test_store() throws {
                var config = ManifoldConfiguration.shared
                config.bundleIdentifier = "com.manifoldkit.tests.toolate.\\(UUID().uuidString)"
                ManifoldConfiguration.shared = config
                try KeychainService.store(key: "k", account: "a")
            }
        }
        """.write(to: scopedOutsideSetUpFile, atomically: true, encoding: .utf8)

        let violations = try Self.violations(testsRoot: tmp, excludedFileNames: [])
        XCTAssertEqual(
            Set(violations),
            ["ManifoldSecretsTests/UnscopedTests.swift", "ManifoldSecretsTests/ScopedOutsideSetUpTests.swift"],
            "The unscoped class and the class that scopes only inside a test body (not setUp) must both be flagged; the correctly-scoped class must not be"
        )

        let exempted = try Self.violations(
            testsRoot: tmp,
            excludedFileNames: ["UnscopedTests.swift", "ScopedOutsideSetUpTests.swift"]
        )
        XCTAssertTrue(exempted.isEmpty, "Excluded file names must exempt their violations")
    }

    // MARK: - Detection

    /// Full audit pipeline: walk `testsRoot`, skip `excludedFileNames`, and
    /// return every file (as a `relative/path`) that writes to the Keychain
    /// without scoping `ManifoldConfiguration.shared` inside `setUp`.
    static func violations(testsRoot: URL, excludedFileNames: Set<String>) throws -> [String] {
        let swiftFiles = try Self.enumerateSwiftFiles(under: testsRoot)

        var violations: [String] = []
        for fileURL in swiftFiles {
            if excludedFileNames.contains(fileURL.lastPathComponent) { continue }

            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            guard Self.writesToKeychain(fileContent: content) else { continue }
            guard !Self.scopesConfigurationInSetUp(fileContent: content) else { continue }

            violations.append(Self.relativePath(of: fileURL, under: testsRoot))
        }
        return violations
    }

    /// `true` if any non-comment line contains one of `keychainWriteNeedles`.
    static func writesToKeychain(fileContent: String) -> Bool {
        for rawLine in fileContent.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") { continue }
            for needle in keychainWriteNeedles where rawLine.contains(needle) {
                return true
            }
        }
        return false
    }

    /// `true` if an `override func setUp` in `fileContent` assigns
    /// `ManifoldConfiguration.shared` somewhere in its body. Uses a simple
    /// brace-depth scan from the `func setUp(` line to its matching close —
    /// sufficient for this codebase's one-brace-per-declaration style, not a
    /// general Swift parser.
    static func scopesConfigurationInSetUp(fileContent: String) -> Bool {
        var inSetUp = false
        var depth = 0
        var seenOpenBrace = false

        for rawLine in fileContent.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*")

            if !inSetUp {
                guard !isComment, rawLine.contains("func setUp(") else { continue }
                inSetUp = true
                depth = 0
                seenOpenBrace = false
            }

            if !isComment, rawLine.contains("ManifoldConfiguration.shared =") {
                return true
            }

            for character in rawLine {
                if character == "{" {
                    depth += 1
                    seenOpenBrace = true
                } else if character == "}" {
                    depth -= 1
                }
            }

            if seenOpenBrace, depth <= 0 {
                // End of this setUp's body — keep scanning in case the file
                // (unusually) declares more than one.
                inSetUp = false
            }
        }
        return false
    }

    // MARK: - Helpers (mirrors UserDefaultsStandardAuditTest's shape)

    private static func locateTestsDirectory(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "KeychainNamespaceIsolationAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/ from #filePath",
        ])
    }

    private static func enumerateSwiftFiles(under root: URL) throws -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }

    private static func relativePath(of fileURL: URL, under root: URL) -> String {
        let filePath = fileURL.path
        let rootPath = root.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return fileURL.lastPathComponent
    }

    /// Builds a fresh, UUID-suffixed temp directory and returns it fully
    /// resolved via POSIX `realpath()` — `/var` is an APFS firmlink to
    /// `/private/var`, and `FileManager`'s enumerator returns the resolved
    /// form for every child it walks, so an unresolved root would break the
    /// relative-path prefix strip. Mirrors
    /// `UserDefaultsStandardAuditTest.makeSabotageTempDirectory`.
    private static func makeSabotageTempDirectory(name: String) throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
}
