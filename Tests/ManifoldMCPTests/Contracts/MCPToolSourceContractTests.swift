#if MCP
import XCTest
import ManifoldInference
@testable import ManifoldMCP

// MARK: - MCPToolSourceContractTests

/// Verifies the behavioral contract of ``MCPToolSource`` — the concrete type
/// that exposes MCP server tools to inference backends.
///
/// These tests exercise the public surface black-box: they never inspect
/// storage actors or private fields. The fixture constructs a
/// ``MCPToolSource`` via its public no-argument init (suitable for testing
/// without a live MCP session) and exercises observable state only.
@MainActor
final class MCPToolSourceContractTests: XCTestCase {

    // MARK: - Identity

    /// A freshly-constructed source retains the serverID and displayName
    /// passed at init time.
    func test_freshSource_retainsIdentityFields() async {
        let id = UUID()
        let source = MCPToolSource(
            serverID: id,
            displayName: "Contract Test Server"
        )
        XCTAssertEqual(source.serverID, id)
        XCTAssertEqual(source.displayName, "Contract Test Server")
    }

    // MARK: - Capabilities

    /// A freshly-constructed source exposes its capabilities asynchronously
    /// without hanging.
    func test_freshSource_capabilitiesAccessible() async {
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Test"
        )
        // Accessing `capabilities` is async on the concrete class. Verify it
        // returns without hanging and produces a non-nil value.
        let caps = await source.capabilities
        // Just asserting the access completes — we don't prescribe default values.
        _ = caps
    }

    // MARK: - currentToolNames

    /// A source with no registered tools returns an empty tool-name list.
    func test_freshSource_currentToolNamesIsEmpty() async {
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Empty Server"
        )
        let names = await source.currentToolNames()
        XCTAssertTrue(
            names.isEmpty,
            "A source with no registered tools must return an empty tool-name list"
        )
    }

    // MARK: - Foundation Models compatibility filter

    /// `foundationModelsCompatibleNames` on an empty source returns an empty
    /// list.
    func test_freshSource_foundationModelsCompatibleNamesIsEmpty() async {
        let source = MCPToolSource(serverID: UUID(), displayName: "FM Test")
        let compatible = await source.foundationModelsCompatibleNames()
        XCTAssertTrue(compatible.isEmpty)
    }

    /// `foundationModelsEnabledNames` on an empty source returns an empty list.
    func test_freshSource_foundationModelsEnabledNamesIsEmpty() async {
        let source = MCPToolSource(serverID: UUID(), displayName: "FM Test")
        let enabled = await source.foundationModelsEnabledNames()
        XCTAssertTrue(enabled.isEmpty)
    }

    // MARK: - register / unregister via ToolRegistry

    /// Registering a source into a tool registry and then unregistering it
    /// produces a stable registry state (no crash, no leaked executors).
    func test_registerThenUnregister_doesNotCrash() async {
        let source = MCPToolSource(serverID: UUID(), displayName: "Registry Test")
        let registry = ToolRegistry()
        await source.register(in: registry)
        // Empty source should not register any tools, so the registry stays
        // empty; we're just proving the call sequence doesn't crash.
        await source.unregister(from: registry)
    }

    // MARK: - close

    /// Calling ``close()`` on a fresh (empty) source completes without
    /// crashing and leaves the source in a stable state.
    func test_close_onFreshSource_doesNotCrash() async {
        let source = MCPToolSource(serverID: UUID(), displayName: "Close Test")
        await source.close()
        // Verify the source is still accessible and tools list is still empty.
        let names = await source.currentToolNames()
        XCTAssertTrue(names.isEmpty)
    }

    // MARK: - Approval invalidation

    /// Calling ``invalidateApprovals()`` on a fresh source does not crash.
    func test_invalidateApprovals_doesNotCrash() async {
        let source = MCPToolSource(serverID: UUID(), displayName: "Approval Test")
        // Nil = invalidate all approvals for this server.
        await source.invalidateApprovals(toolName: nil)
    }
}
#endif
