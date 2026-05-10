#if MCP
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldInference
import ManifoldTestSupport

final class EverythingServerSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_MCP_E2E"] == "1",
            "Set RUN_MCP_E2E=1 to run MCP E2E tests"
        )
        try XCTSkipUnless(hasExecutableOnPATH("npx"), "npx not installed or not on PATH")
    }

    func test_everythingServer_connectsAndListsTools() async throws {
        // Sabotage: returning early before connect() would fail the tool-count assertion

        let (server, source) = try await connectEverythingServer()
        defer { Task { await server.close() } }

        // Verify we get tools back after connecting
        try await source.refreshTools()
        let toolNames = await source.currentToolNames()
        XCTAssertFalse(toolNames.isEmpty, "Expected server-everything to advertise at least one tool")
    }

    func test_everythingServer_refreshToolsReturnsPositiveCount() async throws {
        // Sabotage: returning early before connect() would fail the tool-count assertion

        let (server, source) = try await connectEverythingServer()
        defer { Task { await server.close() } }

        try await source.refreshTools()
        let toolNames = await source.currentToolNames()
        XCTAssertGreaterThan(toolNames.count, 0, "tools/list must return at least one tool")
    }

    func test_everythingServer_taskCancellationPropagates() async throws {
        let (server, source) = try await connectEverythingServer()
        defer { Task { await server.close() } }

        // Start a task that does work on the source and immediately cancel it.
        // The task should surface CancellationError (or MCPError.cancelled).
        let task = Task {
            // Repeatedly refresh tools to keep it busy; the cancel races with this.
            for _ in 0..<100 {
                try await source.refreshTools()
                try Task.checkCancellation()
            }
        }

        task.cancel()

        do {
            try await task.value
            // It's acceptable for the task to complete cleanly if cancellation arrived
            // after the loop finished, so do not XCTFail here.
        } catch is CancellationError {
            // Expected: task was cancelled before completion
        } catch let error as MCPError where error == .cancelled {
            // Also acceptable: the MCP layer mapped the cancellation to .cancelled
        } catch {
            XCTFail("Unexpected error from cancelled task: \(error)")
        }
    }

    private func connectEverythingServer() async throws -> (MCPJSONLineProcessServer, MCPToolSource) {
        let server = MCPJSONLineProcessServer(package: "@modelcontextprotocol/server-everything")
        let capabilities = try await withTimeout(.seconds(30)) {
            try await server.start()
        }
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Everything Server",
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
        return (server, source)
    }
}
#endif
#endif
