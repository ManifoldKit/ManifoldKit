#if Tools
import XCTest
import BaseChatInference
@testable import BaseChatTools

final class SampleRepoSearchToolTests: XCTestCase {

    func test_findsLiteralMatchAcrossFiles() async throws {
        let sandbox = try makeTempSandbox(files: [
            "alpha.md": "one two THREE\nfour Five six",
            "beta.txt": "seven THREE eight",
            "gamma.swift": "// no match here"
        ])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = SampleRepoSearchTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"three"}"#))
        XCTAssertNil(result.errorKind)

        let decoded = try decodeResult(result.content)
        XCTAssertEqual(decoded.matches.count, 2, "expected one match per file; got \(decoded.matches)")
        XCTAssertTrue(decoded.matches.contains { $0.path == "alpha.md" && $0.line == 1 })
        XCTAssertTrue(decoded.matches.contains { $0.path == "beta.txt" && $0.line == 1 })
        XCTAssertFalse(decoded.truncated)
    }

    func test_caseInsensitiveMatch() async throws {
        let sandbox = try makeTempSandbox(files: ["file.md": "HELLO world"])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = SampleRepoSearchTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"hello"}"#))
        let decoded = try decodeResult(result.content)
        XCTAssertEqual(decoded.matches.count, 1)
        XCTAssertTrue(decoded.matches[0].snippet.contains("HELLO"))
    }

    func test_skipsBinaryAndUnsupportedExtensions() async throws {
        let sandbox = try makeTempSandbox(files: [
            "readme.md": "needle here",
            "image.png": "needle",
            "binary.dat": "needle"
        ])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = SampleRepoSearchTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"needle"}"#))
        let decoded = try decodeResult(result.content)
        XCTAssertEqual(decoded.matches.count, 1)
        XCTAssertEqual(decoded.matches[0].path, "readme.md")
    }

    func test_recursesIntoSubdirectories() async throws {
        let sandbox = try makeTempSandbox(files: [:])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let subdir = sandbox.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "hidden gem".write(to: subdir.appendingPathComponent("deep.md"), atomically: true, encoding: .utf8)

        let executor = SampleRepoSearchTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"gem"}"#))
        let decoded = try decodeResult(result.content)
        XCTAssertEqual(decoded.matches.count, 1)
        XCTAssertEqual(decoded.matches[0].path, "notes/deep.md")
    }

    func test_truncatesAtLimit() async throws {
        var files: [String: String] = [:]
        for i in 0..<30 {
            files["f\(i).md"] = "match line\n"
        }
        let sandbox = try makeTempSandbox(files: files)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = SampleRepoSearchTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"match","max_results":5}"#))
        let decoded = try decodeResult(result.content)
        XCTAssertEqual(decoded.matches.count, 5)
        XCTAssertTrue(decoded.truncated)
    }

    func test_perFileCapPreventsSingleFileMonopoly() async throws {
        let heavy = (0..<20).map { "needle line \($0)" }.joined(separator: "\n")
        let sandbox = try makeTempSandbox(files: [
            "heavy.md": heavy,
            "other.md": "needle once"
        ])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = SampleRepoSearchTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"needle","max_results":50}"#))
        let decoded = try decodeResult(result.content)

        let heavyCount = decoded.matches.filter { $0.path == "heavy.md" }.count
        XCTAssertLessThanOrEqual(heavyCount, SampleRepoSearchTool.perFileMatchCap,
                                 "heavy.md should be capped at \(SampleRepoSearchTool.perFileMatchCap)")
        XCTAssertTrue(decoded.matches.contains { $0.path == "other.md" },
                      "other.md must still appear after heavy.md hits the cap")
    }

    func test_emptyQueryRejected() async throws {
        let sandbox = try makeTempSandbox(files: ["x.md": "content"])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = SampleRepoSearchTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"   "}"#))
        XCTAssertEqual(result.errorKind, .invalidArguments)
    }

    func test_missingRootReturnsNotFound() async throws {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("bck-ghost-\(UUID().uuidString)", isDirectory: true)
        let executor = SampleRepoSearchTool.makeExecutor(root: ghost)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"anything"}"#))
        XCTAssertEqual(result.errorKind, .notFound)
    }

    func test_maxResultsClampedToAtLeastOne() async throws {
        let sandbox = try makeTempSandbox(files: [
            "a.md": "needle one",
            "b.md": "needle two",
            "c.md": "needle three"
        ])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = SampleRepoSearchTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"needle","max_results":0}"#))
        XCTAssertNil(result.errorKind)

        let decoded = try decodeResult(result.content)
        // With matches present, a zero request must still return at least one
        // match — the tool clamps the request to 1 rather than returning empty.
        XCTAssertGreaterThanOrEqual(decoded.matches.count, 1)
    }

    func test_maxResultsClampedToHardCap() async throws {
        // Seed enough matches to exceed the hard cap. One match per file keeps
        // us clear of the per-file cap.
        var files: [String: String] = [:]
        let needed = SampleRepoSearchTool.maxMatchesHardCap + 20
        for i in 0..<needed {
            files["file\(i).md"] = "needle line"
        }
        let sandbox = try makeTempSandbox(files: files)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = SampleRepoSearchTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"needle","max_results":5000}"#))
        let decoded = try decodeResult(result.content)
        XCTAssertEqual(decoded.matches.count, SampleRepoSearchTool.maxMatchesHardCap)
        XCTAssertTrue(decoded.truncated)
    }

    func test_longLineTrimmedToSnippetLimit() async throws {
        // Single 500-character line containing the query. The tool should trim
        // to 200 chars plus an ellipsis marker so we never blow the prompt budget.
        let longLine = String(repeating: "abc needle xyz ", count: 40)
        XCTAssertGreaterThan(longLine.count, 200)
        let sandbox = try makeTempSandbox(files: ["long.md": longLine])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = SampleRepoSearchTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"needle"}"#))
        let decoded = try decodeResult(result.content)
        XCTAssertEqual(decoded.matches.count, 1)
        let snippet = decoded.matches[0].snippet
        XCTAssertTrue(snippet.hasSuffix("…"), "expected trimmed snippet to end with ellipsis; got: \(snippet)")
        XCTAssertLessThanOrEqual(snippet.count, 201)
    }

    func test_nonUtf8FileSkipped() async throws {
        let sandbox = try makeTempSandbox(files: [:])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // 0xFF 0xFE alone is not valid UTF-8 — String(contentsOf:encoding:.utf8)
        // will reject the file and the tool should skip it silently.
        let bad = Data([0xFF, 0xFE, 0xFF, 0xFE, 0xFF])
        try bad.write(to: sandbox.appendingPathComponent("garbage.txt"))

        let executor = SampleRepoSearchTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"anything"}"#))
        XCTAssertNil(result.errorKind)
        let decoded = try decodeResult(result.content)
        XCTAssertEqual(decoded.matches.count, 0)
    }

    func test_symlinkEscapingSandboxIsSkipped() async throws {
        let sandbox = try makeTempSandbox(files: ["inside.md": "no match inside"])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // Create the "secret" outside the sandbox. Its contents contain the
        // needle we're searching for, so if the tool follows the symlink it
        // will be visible in the results — and the test will catch it.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("bck-outside-\(UUID().uuidString).md")
        try "needle secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        // Place a symlink under the sandbox pointing at the external file.
        let link = sandbox.appendingPathComponent("escape.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let executor = SampleRepoSearchTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"query":"needle"}"#))
        XCTAssertNil(result.errorKind)
        let decoded = try decodeResult(result.content)
        XCTAssertFalse(decoded.matches.contains { $0.path == "escape.md" },
                       "symlink that escapes the sandbox must not be followed; got matches: \(decoded.matches)")
        XCTAssertFalse(decoded.matches.contains { $0.snippet.contains("secret") },
                       "external file's contents must not leak through the symlink")
    }

    // MARK: - Helpers

    private func parseJSON(_ s: String) throws -> JSONSchemaValue {
        try JSONDecoder().decode(JSONSchemaValue.self, from: Data(s.utf8))
    }

    private func decodeResult(_ content: String) throws -> SampleRepoSearchTool.Result {
        try JSONDecoder().decode(SampleRepoSearchTool.Result.self, from: Data(content.utf8))
    }

    private func makeTempSandbox(files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bck-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return url
    }
}
#endif
