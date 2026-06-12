import XCTest
import ManifoldInference
@testable import ManifoldTools

final class ReferenceToolsTests: XCTestCase {

    // MARK: - NowTool

    func test_nowTool_returnsOutOfDistributionFixture() async throws {
        unsetenv("MANIFOLD_TOOLS_NOW_FIXTURE")
        let executor = NowTool.makeExecutor()
        let result = try await executor.execute(arguments: .object([:]))
        XCTAssertNil(result.errorKind)
        XCTAssertTrue(result.content.contains(NowTool.defaultFixture),
                      "expected default fixture; got \(result.content)")
    }

    func test_nowTool_honoursEnvOverride() async throws {
        setenv("MANIFOLD_TOOLS_NOW_FIXTURE", "2030-02-02T00:00:00Z", 1)
        defer { unsetenv("MANIFOLD_TOOLS_NOW_FIXTURE") }
        let executor = NowTool.makeExecutor()
        let result = try await executor.execute(arguments: .object([:]))
        XCTAssertTrue(result.content.contains("2030-02-02T00:00:00Z"),
                      "expected env-overridden fixture; got \(result.content)")
    }

    // MARK: - CalcTool

    func test_calcTool_multipliesCorrectly() async throws {
        let executor = CalcTool.makeExecutor()
        let result = try await executor.execute(arguments: parseJSON(#"{"a":7823,"op":"*","b":41}"#))
        XCTAssertNil(result.errorKind)
        XCTAssertTrue(result.content.contains("320743"), "got \(result.content)")
    }

    func test_calcTool_divisionByZeroReturnsInvalidArguments() async throws {
        let executor = CalcTool.makeExecutor()
        let result = try await executor.execute(arguments: parseJSON(#"{"a":1,"op":"/","b":0}"#))
        XCTAssertEqual(result.errorKind, .invalidArguments)
        XCTAssertTrue(result.content.contains("division by zero"), "got \(result.content)")
    }

    func test_calcTool_unknownOperatorReturnsInvalidArguments() async throws {
        let executor = CalcTool.makeExecutor()
        let result = try await executor.execute(arguments: parseJSON(#"{"a":1,"op":"^","b":2}"#))
        XCTAssertEqual(result.errorKind, .invalidArguments)
    }

    // MARK: - ReadFileTool

    func test_readFileTool_readsFromSandbox() async throws {
        let sandbox = try makeTempSandbox(files: ["hello.txt": "payload-A"])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = ReadFileTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"path":"hello.txt"}"#))
        XCTAssertNil(result.errorKind)
        XCTAssertTrue(result.content.contains("payload-A"), "got \(result.content)")
    }

    func test_readFileTool_rejectsPathEscape() async throws {
        let sandbox = try makeTempSandbox(files: [:])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = ReadFileTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"path":"../etc/passwd"}"#))
        XCTAssertEqual(result.errorKind, .permissionDenied, "expected .permissionDenied for escape; got \(String(describing: result.errorKind))")
    }

    func test_readFileTool_rejectsAbsolutePath() async throws {
        let sandbox = try makeTempSandbox(files: [:])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = ReadFileTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"path":"/etc/hosts"}"#))
        XCTAssertEqual(result.errorKind, .permissionDenied)
    }

    func test_readFileTool_missingFileReturnsNotFound() async throws {
        let sandbox = try makeTempSandbox(files: [:])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = ReadFileTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"path":"ghost.txt"}"#))
        XCTAssertEqual(result.errorKind, .notFound)
    }

    // MARK: - ListDirTool

    func test_listDirTool_enumeratesSandboxRoot() async throws {
        let sandbox = try makeTempSandbox(files: [
            "a.txt": "one", "b.txt": "two", "c.txt": "three", ".hidden": "skip"
        ])
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let executor = ListDirTool.makeExecutor(root: sandbox)
        let result = try await executor.execute(arguments: parseJSON(#"{"dir":"."}"#))
        XCTAssertNil(result.errorKind)
        for name in ["a.txt", "b.txt", "c.txt"] {
            XCTAssertTrue(result.content.contains(name), "missing \(name) in \(result.content)")
        }
        XCTAssertFalse(result.content.contains(".hidden"), "hidden file should be filtered")
    }

    // MARK: - HttpGetFixtureTool

    func test_httpGetFixtureTool_returnsCannedResponse() async throws {
        let executor = HttpGetFixtureTool.makeExecutor()
        let result = try await executor.execute(arguments: parseJSON(#"{"url":"https://fixture.manifold/weather"}"#))
        XCTAssertNil(result.errorKind)
        XCTAssertTrue(result.content.contains("Dublin"), "got \(result.content)")
    }

    func test_httpGetFixtureTool_rejectsRealNetworkWhenFlagOff() async throws {
        let executor = HttpGetFixtureTool.makeExecutor(allowRealNetwork: false)
        let result = try await executor.execute(arguments: parseJSON(#"{"url":"https://example.com/"}"#))
        XCTAssertEqual(result.errorKind, .permissionDenied)
    }

    // MARK: - Helpers

    private func parseJSON(_ s: String) throws -> JSONSchemaValue {
        let data = Data(s.utf8)
        return try JSONDecoder().decode(JSONSchemaValue.self, from: data)
    }

    private func makeTempSandbox(files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifold-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return url
    }
}
