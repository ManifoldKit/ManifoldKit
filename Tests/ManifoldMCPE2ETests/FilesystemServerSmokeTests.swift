#if MCP
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldInference
import ManifoldTestSupport

final class FilesystemServerSmokeTests: XCTestCase {
    private var sandboxRoot: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_MCP_E2E"] == "1",
            "Set RUN_MCP_E2E=1 to run MCP filesystem E2E tests."
        )
        try XCTSkipUnless(hasExecutableOnPATH("npx"), "npx not installed or not on PATH")
    }

    override func tearDownWithError() throws {
        if let sandboxRoot {
            try? FileManager.default.removeItem(at: sandboxRoot)
        }
        try super.tearDownWithError()
    }

    func test_filesystemServer_listsReadsWritesAndRejectsTraversal() async throws {
        let sandbox = try makeProjectSandbox(named: "mcp-filesystem-e2e")
        sandboxRoot = sandbox
        let allowedRoot = sandbox.appendingPathComponent("allowed", isDirectory: true)
        let outside = sandbox.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)

        let server = MCPJSONLineProcessServer(
            package: "@modelcontextprotocol/server-filesystem",
            args: [allowedRoot.path]
        )
        let capabilities = try await withTimeout(.seconds(30)) {
            try await server.start()
        }
        XCTAssertEqual(capabilities.serverName, "secure-filesystem-server")
        defer { Task { await server.close() } }

        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Filesystem Server",
            capabilities: capabilities,
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .perCall,
            listTools: {
                try await server.sendRequest(method: "tools/list", params: nil)
            },
            callTool: { toolName, arguments in
                try await server.sendRequest(
                    method: "tools/call",
                    params: .object([
                        "name": .string(toolName),
                        "arguments": arguments,
                    ])
                )
            }
        )

        try await withTimeout(.seconds(30)) {
            try await source.refreshTools()
        }
        let toolNames = await source.currentToolNames()
        XCTAssertTrue(toolNames.contains("list_directory"), "server-filesystem should advertise list_directory")
        XCTAssertTrue(toolNames.contains("read_file"), "server-filesystem should advertise read_file")
        XCTAssertTrue(toolNames.contains("write_file"), "server-filesystem should advertise write_file")

        let registry = await MainActor.run { ToolRegistry() }
        await source.register(in: registry)
        let registeredNames = await MainActor.run { registry.definitions.map(\.name) }
        XCTAssertTrue(registeredNames.contains("write_file"))

        let fileURL = allowedRoot.appendingPathComponent("notes/e2e.txt")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let writeResult = try await withTimeout(.seconds(30)) {
            await registry.dispatch(ToolCall(
                id: "write-e2e",
                toolName: "write_file",
                arguments: #"{"path":"\#(fileURL.path)","content":"hello from e2e"}"#
            ))
        }
        XCTAssertNil(writeResult.errorKind, writeResult.content)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "hello from e2e")

        let readResult = try await withTimeout(.seconds(30)) {
            await registry.dispatch(ToolCall(
                id: "read-e2e",
                toolName: "read_file",
                arguments: #"{"path":"\#(fileURL.path)"}"#
            ))
        }
        XCTAssertNil(readResult.errorKind, readResult.content)
        XCTAssertTrue(readResult.content.contains("hello from e2e"))

        let listResult = try await withTimeout(.seconds(30)) {
            await registry.dispatch(ToolCall(
                id: "list-e2e",
                toolName: "list_directory",
                arguments: #"{"path":"\#(allowedRoot.appendingPathComponent("notes").path)"}"#
            ))
        }
        XCTAssertNil(listResult.errorKind, listResult.content)
        XCTAssertTrue(listResult.content.contains("e2e.txt"))

        let traversalPath = "\(allowedRoot.path)/../outside.txt"
        let traversalResult = try await withTimeout(.seconds(30)) {
            await registry.dispatch(ToolCall(
                id: "traversal-e2e",
                toolName: "read_file",
                arguments: #"{"path":"\#(traversalPath)"}"#
            ))
        }
        XCTAssertNotNil(traversalResult.errorKind, "server-filesystem must reject traversal outside allowed roots")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
    }

    private func makeProjectSandbox(named prefix: String) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
#endif
#endif
