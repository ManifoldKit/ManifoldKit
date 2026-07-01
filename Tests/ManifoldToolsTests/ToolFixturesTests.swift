import XCTest
@testable import ManifoldTools

/// Confirms the fixture tree resolves via `Bundle.module`, not the process
/// working directory — the same regression class `ScenarioLoader` had before
/// #2042. `ScenarioRunnerTests.test_loadBuiltIn...` proves the analogous thing
/// for scenarios by running under a foreign CWD; this proves it for the
/// fixture tree by asserting the known files are present and readable
/// regardless of what CWD the test happens to run under.
final class ToolFixturesTests: XCTestCase {

    func test_bundledRoot_resolvesKnownFixtureFiles() throws {
        let root = ToolFixtures.bundledRoot()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
            "expected bundled fixture root to exist at \(root.path)"
        )
        XCTAssertTrue(isDirectory.boolValue)

        for relativePath in ["a.txt", "b.txt", "c.txt", "example.txt", "shopping-list.txt", "oversize-output.txt"] {
            let url = root.appendingPathComponent(relativePath)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "expected bundled fixture '\(relativePath)' at \(url.path)"
            )
        }

        for relativePath in ["notes/standup.md", "notes/archive.md", "readmes/backend-a.md", "readmes/backend-b.md"] {
            let url = root.appendingPathComponent(relativePath)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "expected bundled fixture '\(relativePath)' at \(url.path)"
            )
        }
    }

    func test_readFileTool_defaultRoot_matchesBundledRoot() {
        XCTAssertEqual(ReadFileTool.defaultRoot(), ToolFixtures.bundledRoot())
    }
}
