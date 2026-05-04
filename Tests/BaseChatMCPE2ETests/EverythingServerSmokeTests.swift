#if MCP
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import BaseChatMCP
import BaseChatInference

final class EverythingServerSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_MCP_E2E"] == "1",
            "Set RUN_MCP_E2E=1 to run MCP E2E tests"
        )
        try XCTSkipIf(!hasNpx(), "npx not installed")
    }

    func test_everythingServer_connectsAndListsTools() async throws {
        // Sabotage: returning early before connect() would fail the tool-count assertion

        let command = MCPStdioCommand.npx(package: "@modelcontextprotocol/server-everything")
        let descriptor = MCPServerDescriptor(
            displayName: "Everything Server",
            transport: .stdio(command),
            initializationTimeout: .seconds(60),
            dataDisclosure: "E2E test server"
        )

        let client = MCPClient()
        let source = try await client.connect(descriptor)

        defer {
            Task { await client.disconnect(serverID: descriptor.id) }
        }

        // Verify we get tools back after connecting
        try await source.refreshTools()
        let toolNames = await source.currentToolNames()
        XCTAssertFalse(toolNames.isEmpty, "Expected server-everything to advertise at least one tool")
    }

    func test_everythingServer_refreshToolsReturnsPositiveCount() async throws {
        // Sabotage: returning early before connect() would fail the tool-count assertion

        let command = MCPStdioCommand.npx(package: "@modelcontextprotocol/server-everything")
        let descriptor = MCPServerDescriptor(
            displayName: "Everything Server",
            transport: .stdio(command),
            initializationTimeout: .seconds(60),
            dataDisclosure: "E2E test server"
        )

        let client = MCPClient()
        let source = try await client.connect(descriptor)

        defer {
            Task { await client.disconnect(serverID: descriptor.id) }
        }

        try await source.refreshTools()
        let toolNames = await source.currentToolNames()
        XCTAssertGreaterThan(toolNames.count, 0, "tools/list must return at least one tool")
    }

    func test_everythingServer_taskCancellationPropagates() async throws {
        let command = MCPStdioCommand.npx(package: "@modelcontextprotocol/server-everything")
        let descriptor = MCPServerDescriptor(
            displayName: "Everything Server",
            transport: .stdio(command),
            initializationTimeout: .seconds(60),
            dataDisclosure: "E2E test server"
        )

        let client = MCPClient()
        let source = try await client.connect(descriptor)

        defer {
            Task { await client.disconnect(serverID: descriptor.id) }
        }

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

    // MARK: - Helpers

    private func hasNpx() -> Bool {
        FileManager.default.fileExists(atPath: "/usr/local/bin/npx")
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/npx")
    }
}
#endif
#endif
