import XCTest

/// Guards against regression of PR #1409: `ManifoldTestSupport` must NOT
/// transitively pull in XCTest, and the XCTest-dependent contract mixins
/// must stay in a dedicated `ManifoldContractTestSupport` target.
///
/// ## Why this matters
///
/// PR #1409 attempted to consolidate the two targets by collapsing
/// `Sources/ManifoldContractTestSupport/*.swift` into
/// `Sources/ManifoldTestSupport/Contracts/` under a file-level
/// `#if canImport(XCTest)` gate. On the developer's local Mac this looked
/// safe — `otool -L fuzz-chat` showed no XCTest references because Swift
/// strips unused symbols at link time when the host compiler can resolve
/// XCTest. On the CI runner, however, `canImport(XCTest)` evaluates true
/// while the XCTest framework is not on the runtime library search path
/// outside of an xctest host process. The result was a dyld crash at the
/// first invocation of `swift run fuzz-chat ...`:
///
///     dyld[4010]: Library not loaded: @rpath/libXCTestSwiftSupport.dylib
///       Referenced from: .../fuzz-chat
///
/// The fix is structural: XCTest-tainted code lives in its own target so
/// non-test executables (`fuzz-chat` today, anything else tomorrow) can
/// depend on `ManifoldTestSupport` without inheriting an XCTest link
/// dependency they cannot satisfy at runtime.
///
/// ## What this test enforces
///
/// 1. `Sources/ManifoldContractTestSupport/` exists and contains at least
///    one `*Contract.swift` file. (Sentinel against an "accidental" merge
///    that deletes the directory.)
/// 2. `Sources/ManifoldTestSupport/` contains no file with a top-level
///    `import XCTest`. (Sentinel against re-introducing the
///    `#if canImport(XCTest)` pattern that masked the crash.)
/// 3. `Package.swift` declares both `ManifoldTestSupport` and
///    `ManifoldContractTestSupport` as separate `.target(...)` entries.
///
/// ## Fixing a violation
///
/// Do not merge the two targets. If you need a helper that some tests
/// share but executables also need, put it in `ManifoldTestSupport`
/// (XCTest-free). If it must use `XCTAssert*` / `XCTestCase`, put it in
/// `ManifoldContractTestSupport`.
///
/// ``xctestImportOffenders(supportDir:)`` and
/// ``executableTargetOffenders(manifest:)`` are the detection functions
/// shared by their audit and the in-file sabotage tests.
final class ContractTestSupportSplitAuditTest: XCTestCase {

    func test_manifoldContractTestSupport_directoryExists() throws {
        let repoRoot = try Self.repoRoot()
        let contractDir = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("ManifoldContractTestSupport")

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: contractDir.path,
            isDirectory: &isDir
        )
        XCTAssertTrue(exists && isDir.boolValue,
                      "Sources/ManifoldContractTestSupport/ must exist as a directory. See PR #1409 retrospective in this file's doc comment.")

        let contents = try FileManager.default.contentsOfDirectory(atPath: contractDir.path)
        let contractFiles = contents.filter { $0.hasSuffix("Contract.swift") }
        XCTAssertFalse(contractFiles.isEmpty,
                       "Sources/ManifoldContractTestSupport/ must contain at least one *Contract.swift file.")
    }

    func test_manifoldTestSupport_doesNotImportXCTest() throws {
        let repoRoot = try Self.repoRoot()
        let supportDir = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("ManifoldTestSupport")

        let offenders = Self.xctestImportOffenders(supportDir: supportDir)

        XCTAssertTrue(
            offenders.isEmpty,
            """
            ManifoldTestSupport must stay XCTest-free so non-test executables
            (e.g. fuzz-chat) can depend on it without a runtime dyld crash.
            Move the offending file(s) to Sources/ManifoldContractTestSupport/.
            Offenders: \(offenders)
            """
        )
    }

    func test_packageManifest_declaresBothTargets() throws {
        let repoRoot = try Self.repoRoot()
        let packageURL = repoRoot.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: packageURL, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("name: \"ManifoldTestSupport\""),
            "Package.swift must declare a target named ManifoldTestSupport."
        )
        XCTAssertTrue(
            manifest.contains("name: \"ManifoldContractTestSupport\""),
            "Package.swift must declare a target named ManifoldContractTestSupport. See PR #1409 retrospective in this file's doc comment."
        )
    }

    /// `ManifoldBackendTestKit` (v0.48, #1749) links XCTest just like
    /// `ManifoldContractTestSupport` — the same dyld constraint applies. No
    /// executable target may depend on either XCTest-linking target.
    func test_executableTargets_doNotDependOnXCTestLinkingTargets() throws {
        let repoRoot = try Self.repoRoot()
        let packageURL = repoRoot.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: packageURL, encoding: .utf8)

        let offenders = Self.executableTargetOffenders(manifest: manifest)

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Executable targets must never depend on XCTest-linking targets
            (ManifoldContractTestSupport, ManifoldBackendTestKit) — dyld cannot
            resolve libXCTestSwiftSupport.dylib outside an xctest host (#1409).
            Offenders: \(offenders)
            """
        )
    }

    // MARK: - Sabotage (exercises the same detection functions the audits run)

    /// Plants a file with a top-level `import XCTest` line and a file whose
    /// only mention is a commented-out import, in a temp tree shaped like
    /// `Sources/ManifoldTestSupport/`, and asserts the REAL detection
    /// function flags only the real top-level import.
    func test_sabotage_detectsTopLevelXCTestImport() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("contract-test-support-sabotage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try """
        import XCTest
        func badHelper() {}
        """.write(to: tmp.appendingPathComponent("BadHelper.swift"), atomically: true, encoding: .utf8)

        try """
        #if canImport(XCTest)
        // import XCTest
        func fine() {}
        #endif
        """.write(to: tmp.appendingPathComponent("FineHelper.swift"), atomically: true, encoding: .utf8)

        let offenders = Self.xctestImportOffenders(supportDir: tmp)
        XCTAssertTrue(offenders.contains("BadHelper.swift"), "The planted top-level `import XCTest` must be flagged; got \(offenders)")
        XCTAssertFalse(offenders.contains("FineHelper.swift"), "A commented-out import must not be flagged; got \(offenders)")
    }

    /// Plants an `.executableTarget(...)` block depending on
    /// `ManifoldBackendTestKit` and asserts the REAL detection function
    /// flags it.
    func test_sabotage_detectsExecutableTargetXCTestLinkingDependency() {
        let manifest = """
            .executableTarget(
                name: "bad-tool",
                dependencies: [
                    "ManifoldBackendTestKit",
                ]
            ),
            """

        let offenders = Self.executableTargetOffenders(manifest: manifest)
        XCTAssertTrue(
            offenders.contains { $0.contains("bad-tool") && $0.contains("ManifoldBackendTestKit") },
            "The planted executable-target dependency on ManifoldBackendTestKit must be flagged; got \(offenders)"
        )
    }

    // MARK: - Detection

    /// Walks `supportDir` for `.swift` files with a top-level
    /// `import XCTest` line (also catches the `#if canImport(XCTest)`
    /// shape that masked the crash in PR #1409). Both the audit and the
    /// sabotage test call this.
    static func xctestImportOffenders(supportDir: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: supportDir.path)
        var offenders: [String] = []
        while let relative = enumerator?.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            let url = supportDir.appendingPathComponent(relative)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "import XCTest" {
                    offenders.append(relative)
                    break
                }
            }
        }
        return offenders
    }

    /// Extracts each `.executableTarget(...)` block by brace matching from
    /// the declaration to the matching close paren, then scans its
    /// dependency text for the XCTest-linking target names. Both the audit
    /// and the sabotage test call this.
    static func executableTargetOffenders(manifest: String) -> [String] {
        var offenders: [String] = []
        var searchRange = manifest.startIndex..<manifest.endIndex
        while let declRange = manifest.range(of: ".executableTarget(", range: searchRange) {
            var depth = 1
            var index = declRange.upperBound
            while index < manifest.endIndex, depth > 0 {
                let char = manifest[index]
                if char == "(" { depth += 1 }
                if char == ")" { depth -= 1 }
                index = manifest.index(after: index)
            }
            let block = String(manifest[declRange.lowerBound..<index])
            for tainted in ["\"ManifoldContractTestSupport\"", "\"ManifoldBackendTestKit\""]
            where block.contains(tainted) {
                let name = block.range(of: "name: \"").flatMap { nameStart in
                    block[nameStart.upperBound...].split(separator: "\"").first.map(String.init)
                } ?? "<unknown>"
                offenders.append("\(name) depends on \(tainted)")
            }
            searchRange = index..<manifest.endIndex
        }
        return offenders
    }

    // MARK: - Helpers

    private static func repoRoot() throws -> URL {
        // This test file lives at Tests/ManifoldCoreTests/<this>.swift.
        // Walk up two directories to reach the package root.
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()  // ManifoldCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
    }
}
