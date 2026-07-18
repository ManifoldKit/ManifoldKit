@preconcurrency import XCTest
import Foundation
@testable import ManifoldUIModelManagement

/// Unit tests for ``MCPDataDisclosureConsentStore`` — the gate
/// ``ConnectedServicesView`` uses to enforce "connecting a server never
/// implies approving its tool calls... a plain-language consent card
/// explains data flow *before* first tool exposure" (`docs/UI-REFRESH-2026.md`
/// §6B). The view only calls `coordinator.connect(_:)` (which registers the
/// server's tools into `toolRegistry`) once
/// ``MCPDataDisclosureConsentStore/hasAccepted(serverID:)`` is `true`; this
/// suite pins that store's logic directly since driving the live
/// `MCPClient`/network path is out of scope for a fast unit test.
@MainActor
final class ConnectedServicesConsentTests: XCTestCase {

    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        // Per-test isolated suite — `swift test --parallel` races on
        // `UserDefaults.standard` (AGENTS.md "Inject UserDefaults").
        suiteName = "ConnectedServicesConsentTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        userDefaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func test_hasAccepted_isFalse_beforeFirstExposure() {
        let store = MCPDataDisclosureConsentStore(userDefaults: userDefaults)
        let serverID = UUID()

        // No tool exposure should be gated on this returning false for a
        // server that has never been connected.
        XCTAssertFalse(store.hasAccepted(serverID: serverID))
    }

    func test_accept_flipsHasAccepted_forThatServerOnly() {
        let store = MCPDataDisclosureConsentStore(userDefaults: userDefaults)
        let acceptedServer = UUID()
        let otherServer = UUID()

        store.accept(serverID: acceptedServer)

        XCTAssertTrue(store.hasAccepted(serverID: acceptedServer))
        // Consent is per-server — accepting one server's disclosure must not
        // silently pre-approve a different, never-seen server.
        XCTAssertFalse(store.hasAccepted(serverID: otherServer))
    }

    func test_accept_persistsAcrossStoreInstances_forSameUserDefaults() {
        let serverID = UUID()
        MCPDataDisclosureConsentStore(userDefaults: userDefaults).accept(serverID: serverID)

        // A fresh store instance (mirrors a new `ConnectedServicesView` sheet
        // presentation) backed by the same `UserDefaults` still remembers
        // the prior acceptance — the spec's "you will only see this
        // disclosure the first time you connect this service" contract.
        let reloaded = MCPDataDisclosureConsentStore(userDefaults: userDefaults)
        XCTAssertTrue(reloaded.hasAccepted(serverID: serverID))
    }
}
