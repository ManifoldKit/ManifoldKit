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
/// method in the class still writing to the shared default namespace. The
/// scoped `bundleIdentifier` must also contain `UUID(` — a *fixed* scoped
/// namespace shared by two classes races exactly as before; only a
/// per-test-run-unique one actually closes the window.
///
/// **Detection is file-scoped, not class-scoped**: `violations()` reads
/// whole-file text, so it cannot attribute a Keychain-writing line or a
/// scoping `setUp` to a specific class when a file declares more than one
/// `XCTestCase` subclass. Rather than risk a false negative (a scoping
/// `setUp` in class A silently covering an unscoped class B in the same
/// file), any needle-containing file with more than one `: XCTestCase`
/// declaration is **always** flagged, regardless of whether *some* `setUp`
/// in the file scopes correctly — split the file into one class per file to
/// clear the violation. (As of this writing 16 such multi-class files exist
/// under `Tests/`, none of which contain a Keychain-write needle — this is a
/// latent tightening, not a currently-red one.)
///
/// ## Known limitations (grep-shaped, not a parser)
///
/// This audit fails **closed**, not open, on the following — a false
/// positive (a correctly-isolated class gets flagged) is possible; a false
/// negative (an unscoped class passes) is not:
/// - A scoping assignment written as `ManifoldConfiguration.shared
///   .bundleIdentifier = "..."` (dot on its own line, or otherwise not
///   matching the literal substring `ManifoldConfiguration.shared =`) is not
///   recognised — the audit will flag an already-correct class. Use the
///   `var config = ...; config.bundleIdentifier = ...; ManifoldConfiguration
///   .shared = config` shape shown below, or a direct
///   `ManifoldConfiguration.shared = ManifoldConfiguration(bundleIdentifier:
///   ...)` one-liner.
/// - `override func setUpWithError() throws` is not recognised as a setUp
///   override — only literal `func setUp(` matches. Use `override func
///   setUp()` (or `setUp() async throws`).
///
/// If a class you know is correctly scoped gets flagged, it is almost
/// certainly one of these two shapes — fix the shape rather than working
/// around the audit.
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

        // Guard against the "green because it enumerated zero files" shape:
        // `XCTFail` below only fires `if !violations.isEmpty`, which is
        // trivially satisfied if root resolution or enumeration silently
        // returns nothing. Assert the scan actually found the writer
        // population it should — a floor, not an exact count, so a new
        // Keychain-writing test class doesn't need to bump a magic number.
        // As of this writing there are exactly 8 (all correctly scoped);
        // `test_sabotage_scanFindsRealKeychainWriters` pins that this
        // assertion is real coverage, not a number that happens to be true.
        let keychainWritingFiles = try Self.keychainWritingFiles(testsRoot: testsURL, excludedFileNames: excludedFileNames)
        XCTAssertGreaterThanOrEqual(
            keychainWritingFiles.count, 8,
            "Expected to find at least 8 Keychain-writing test files under Tests/ — found \(keychainWritingFiles.count). If this is 0, the scan likely resolved the wrong root or found no files, which would make the violations check below pass vacuously."
        )

        let violations = try Self.violations(testsRoot: testsURL, excludedFileNames: excludedFileNames)

        if !violations.isEmpty {
            let formatted = violations.sorted().map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                The following test files write to the Keychain (directly via
                `KeychainService.store(`, or indirectly via `.setAPIKey(` /
                `rollbackKeychainKey(`) without scoping
                `ManifoldConfiguration.shared` to a UUID-unique namespace in
                an `override func setUp` in the same file — or (for a
                multi-class file) this audit cannot safely attribute the
                scoping to the writing class at all. Each one races every
                other default-namespace Keychain writer batched into the
                same `swift test --parallel` invocation (see issue #2416).

                \(formatted)

                Add the setUp/tearDown scoping pattern documented in this
                file's header — see
                Tests/ManifoldSecretsTests/KeychainServiceTests.swift for a
                worked example. If the file has more than one XCTestCase
                subclass, split it into one class per file.
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `violations(testsRoot:excludedFileNames:)` the audit runs)

    /// Plants four files in a temp tree shaped like `Tests/`: one that
    /// writes to the Keychain with no scoping (must be flagged), one that
    /// writes to the Keychain and scopes correctly in `setUp` with a
    /// UUID-unique namespace (must NOT be flagged), one that scopes
    /// `ManifoldConfiguration.shared` but outside `setUp` — e.g. inside a
    /// single test body (must still be flagged, because it doesn't protect
    /// the whole class), and one that scopes correctly *inside* `setUp` but
    /// with a **fixed, non-unique** namespace (must still be flagged — two
    /// classes both using that same fixed name would race exactly as
    /// before; only a `UUID()`-suffixed namespace actually closes the
    /// window).
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

        let fixedNamespaceFile = root.appendingPathComponent("FixedNamespaceTests.swift")
        try """
        import XCTest
        final class FixedNamespaceTests: XCTestCase {
            override func setUp() {
                super.setUp()
                // Scoped in setUp, but the namespace is NOT unique per run —
                // two classes using this exact string would still race.
                var config = ManifoldConfiguration.shared
                config.bundleIdentifier = "com.manifoldkit.tests.fixed-name"
                ManifoldConfiguration.shared = config
            }
            func test_store() throws {
                try KeychainService.store(key: "k", account: "a")
            }
        }
        """.write(to: fixedNamespaceFile, atomically: true, encoding: .utf8)

        let violations = try Self.violations(testsRoot: tmp, excludedFileNames: [])
        XCTAssertEqual(
            Set(violations),
            [
                "ManifoldSecretsTests/UnscopedTests.swift",
                "ManifoldSecretsTests/ScopedOutsideSetUpTests.swift",
                "ManifoldSecretsTests/FixedNamespaceTests.swift",
            ],
            "The unscoped class, the class that scopes only inside a test body (not setUp), and the class that scopes in setUp with a non-UUID fixed namespace must all be flagged; only the UUID-scoped-in-setUp class must not be"
        )

        let exempted = try Self.violations(
            testsRoot: tmp,
            excludedFileNames: ["UnscopedTests.swift", "ScopedOutsideSetUpTests.swift", "FixedNamespaceTests.swift"]
        )
        XCTAssertTrue(exempted.isEmpty, "Excluded file names must exempt their violations")
    }

    /// A needle-containing file with more than one `XCTestCase` subclass
    /// must always be flagged, even when one of its classes scopes itself
    /// correctly — the audit reads whole-file text and cannot attribute the
    /// scoping `setUp` to the class that actually needs it.
    func test_sabotage_flagsMultiClassFilesRegardlessOfScoping() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "keychain-namespace-isolation-multiclass-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("ManifoldSecretsTests", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let multiClassFile = root.appendingPathComponent("MultiClassTests.swift")
        try """
        import XCTest

        final class ScopedHelperTests: XCTestCase {
            private var originalConfig: ManifoldConfiguration!
            override func setUp() {
                super.setUp()
                originalConfig = ManifoldConfiguration.shared
                var config = ManifoldConfiguration.shared
                config.bundleIdentifier = "com.manifoldkit.tests.multiclass.\\(UUID().uuidString)"
                ManifoldConfiguration.shared = config
            }
            override func tearDown() {
                ManifoldConfiguration.shared = originalConfig
                super.tearDown()
            }
            func test_noop() {}
        }

        final class UnrelatedWriterTests: XCTestCase {
            // No setUp at all — this class writes to the shared default
            // namespace, but the file as a whole "looks" scoped because of
            // ScopedHelperTests above.
            func test_store() throws {
                try KeychainService.store(key: "k", account: "a")
            }
        }
        """.write(to: multiClassFile, atomically: true, encoding: .utf8)

        let violations = try Self.violations(testsRoot: tmp, excludedFileNames: [])
        XCTAssertEqual(
            violations, ["ManifoldSecretsTests/MultiClassTests.swift"],
            "A needle-containing file with more than one XCTestCase subclass must always be flagged, regardless of whether some class in the file scopes itself"
        )
    }

    /// Pins that `keychainWritingFiles` — the floor-assertion helper the
    /// main audit uses to guard against enumerating zero files — actually
    /// finds real writer files rather than always returning zero for
    /// unrelated reasons (a bug in the helper itself would defeat the floor
    /// assertion just as surely as a bad root).
    func test_sabotage_scanFindsRealKeychainWriters() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "keychain-namespace-isolation-scan-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("ManifoldSecretsTests", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for index in 0..<3 {
            let file = root.appendingPathComponent("Writer\(index)Tests.swift")
            try """
            import XCTest
            final class Writer\(index)Tests: XCTestCase {
                func test_store() throws {
                    try KeychainService.store(key: "k", account: "a")
                }
            }
            """.write(to: file, atomically: true, encoding: .utf8)
        }
        // A file with no needle must not be counted.
        let nonWriterFile = root.appendingPathComponent("UnrelatedTests.swift")
        try """
        import XCTest
        final class UnrelatedTests: XCTestCase {
            func test_noop() {}
        }
        """.write(to: nonWriterFile, atomically: true, encoding: .utf8)

        let writers = try Self.keychainWritingFiles(testsRoot: tmp, excludedFileNames: [])
        XCTAssertEqual(writers.count, 3, "Expected exactly the 3 planted writer files, not the unrelated one")
    }

    // MARK: - Detection

    /// Full audit pipeline: walk `testsRoot`, skip `excludedFileNames`, and
    /// return every file (as a `relative/path`) that writes to the Keychain
    /// without scoping `ManifoldConfiguration.shared` to a UUID-unique
    /// namespace inside `setUp` — or that writes to the Keychain from a
    /// file with more than one `XCTestCase` subclass (see the type's doc
    /// comment on file- vs. class-scoping).
    static func violations(testsRoot: URL, excludedFileNames: Set<String>) throws -> [String] {
        let writingFiles = try Self.keychainWritingFiles(testsRoot: testsRoot, excludedFileNames: excludedFileNames)

        var violations: [String] = []
        for fileURL in writingFiles {
            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""

            if Self.classDeclarationCount(fileContent: content) > 1 {
                violations.append(Self.relativePath(of: fileURL, under: testsRoot))
                continue
            }
            guard !Self.scopesConfigurationInSetUp(fileContent: content) else { continue }

            violations.append(Self.relativePath(of: fileURL, under: testsRoot))
        }
        return violations
    }

    /// Every `.swift` file under `testsRoot` (excluding `excludedFileNames`)
    /// that writes to the Keychain, per `writesToKeychain(fileContent:)`.
    /// Separated from `violations` so the main audit test can assert this
    /// scan actually found something before trusting an empty violations
    /// list — an audit that silently enumerates zero files would otherwise
    /// report a confident, wrong "no violations".
    static func keychainWritingFiles(testsRoot: URL, excludedFileNames: Set<String>) throws -> [URL] {
        let swiftFiles = try Self.enumerateSwiftFiles(under: testsRoot)
        var result: [URL] = []
        for fileURL in swiftFiles {
            if excludedFileNames.contains(fileURL.lastPathComponent) { continue }
            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            if Self.writesToKeychain(fileContent: content) {
                result.append(fileURL)
            }
        }
        return result
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

    /// `true` if an `override func setUp` in `fileContent` **both** assigns
    /// `ManifoldConfiguration.shared` **and** derives the namespace from
    /// `UUID(` — both conditions must hold within the same `setUp` body. An
    /// assignment to a *fixed* (non-unique) namespace is not enough: two
    /// classes adopting the same fixed name would race exactly as before,
    /// so only a per-test-run-unique namespace actually closes the window.
    /// Uses a simple brace-depth scan from the `func setUp(` line to its
    /// matching close — sufficient for this codebase's
    /// one-brace-per-declaration style, not a general Swift parser (see the
    /// "Known limitations" section of this type's doc comment).
    static func scopesConfigurationInSetUp(fileContent: String) -> Bool {
        var inSetUp = false
        var depth = 0
        var seenOpenBrace = false
        var sawAssignment = false
        var sawUUID = false

        for rawLine in fileContent.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*")

            if !inSetUp {
                guard !isComment, rawLine.contains("func setUp(") else { continue }
                inSetUp = true
                depth = 0
                seenOpenBrace = false
                sawAssignment = false
                sawUUID = false
            }

            if !isComment {
                if rawLine.contains("ManifoldConfiguration.shared =") { sawAssignment = true }
                if rawLine.contains("UUID(") { sawUUID = true }
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
                if sawAssignment, sawUUID { return true }
                // End of this setUp's body — keep scanning in case the file
                // (unusually) declares more than one.
                inSetUp = false
            }
        }
        return false
    }

    /// Counts declarations shaped like `class Foo: XCTestCase` (with or
    /// without `final`) on non-comment lines. Used to detect multi-class
    /// files, where this audit's whole-file text scan cannot safely
    /// attribute a scoping `setUp` to the specific class that writes to the
    /// Keychain.
    static func classDeclarationCount(fileContent: String) -> Int {
        var count = 0
        for rawLine in fileContent.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") { continue }
            if rawLine.contains(": XCTestCase") { count += 1 }
        }
        return count
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
