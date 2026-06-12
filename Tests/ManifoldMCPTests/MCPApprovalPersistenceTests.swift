import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldInference

final class MCPApprovalPersistenceTests: XCTestCase {

    func test_approvalSurvivesStoreReinstantiation() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let serverID = UUID()
        let store1 = MCPPersistentToolApprovalStore(defaults: defaults)
        store1.approve(serverID: serverID, toolName: "mytool")

        let store2 = MCPPersistentToolApprovalStore(defaults: defaults)
        let approved = store2.isApproved(serverID: serverID, toolName: "mytool")
        XCTAssertTrue(approved, "Approval must survive re-instantiation")
    }

    func test_revokeAllClearsApprovals() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let serverID = UUID()
        let store = MCPPersistentToolApprovalStore(defaults: defaults)
        store.approve(serverID: serverID, toolName: "tool1")
        store.approve(serverID: serverID, toolName: "tool2")
        store.revokeAll(serverID: serverID)

        let approved = store.isApproved(serverID: serverID, toolName: "tool1")
        XCTAssertFalse(approved, "revokeAll must clear all approvals for the server")
    }

    func test_revokeAllDoesNotAffectOtherServers() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let serverA = UUID()
        let serverB = UUID()
        let store = MCPPersistentToolApprovalStore(defaults: defaults)
        store.approve(serverID: serverA, toolName: "tool1")
        store.approve(serverID: serverB, toolName: "tool1")
        store.revokeAll(serverID: serverA)

        let aApproved = store.isApproved(serverID: serverA, toolName: "tool1")
        let bApproved = store.isApproved(serverID: serverB, toolName: "tool1")
        XCTAssertFalse(aApproved, "revokeAll for serverA must clear serverA's approvals")
        XCTAssertTrue(bApproved, "revokeAll for serverA must not affect serverB's approvals")
    }

    func test_revokeSingleToolLeavesOthersIntact() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let serverID = UUID()
        let store = MCPPersistentToolApprovalStore(defaults: defaults)
        store.approve(serverID: serverID, toolName: "tool1")
        store.approve(serverID: serverID, toolName: "tool2")
        store.revoke(serverID: serverID, toolName: "tool1")

        let tool1Approved = store.isApproved(serverID: serverID, toolName: "tool1")
        let tool2Approved = store.isApproved(serverID: serverID, toolName: "tool2")
        XCTAssertFalse(tool1Approved, "Revoked tool must not be approved")
        XCTAssertTrue(tool2Approved, "Un-revoked tool must remain approved")
    }

    func test_unapprovedToolReturnsFalse() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MCPPersistentToolApprovalStore(defaults: defaults)
        let approved = store.isApproved(serverID: UUID(), toolName: "unknown")
        XCTAssertFalse(approved)
    }

    // Two stores backed by the same UserDefaults suite are equivalent to two app
    // sessions (the second reads what the first wrote). This proves durability.
    func test_approvalWrittenByOneInstanceIsReadableByAnother() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let serverID = UUID()
        let writer = MCPPersistentToolApprovalStore(defaults: defaults)
        writer.approve(serverID: serverID, toolName: "search")

        let reader = MCPPersistentToolApprovalStore(defaults: defaults)
        XCTAssertTrue(
            reader.isApproved(serverID: serverID, toolName: "search"),
            "Approval written by one store must be readable by another backed by the same UserDefaults suite"
        )
    }
}
