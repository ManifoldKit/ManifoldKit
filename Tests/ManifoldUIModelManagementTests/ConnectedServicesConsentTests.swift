@preconcurrency import XCTest
import SwiftUI
import ViewInspector
import Foundation
import ManifoldInference
import ManifoldMCP
@testable import ManifoldUIModelManagement

/// Unit tests for ``MCPDataDisclosureConsentStore`` — the gate
/// ``ConnectedServicesView`` uses to enforce "connecting a server never
/// implies approving its tool calls... a plain-language consent card
/// explains data flow *before* first tool exposure" (`docs/UI-REFRESH-2026.md`
/// §6B). The view only calls `coordinator.connect(_:)` (which registers the
/// server's tools into `toolRegistry`) once
/// ``MCPDataDisclosureConsentStore/hasAccepted(serverID:)`` is `true`; the
/// first three tests pin that store's logic directly (fast, no view
/// rendered), and
/// ``test_connectButton_forUnacceptedServer_doesNotStartConnectionBeforeConsent()``
/// proves the actual call site (the `if hasAccepted(...)` guard inside
/// `ConnectedServicesView`'s row `Button("Connect")`) enforces it too —
/// manually sabotage-verified: deleting that guard (always calling
/// `coordinator.connect(descriptor)`) makes this test fail, confirmed by
/// hand before writing it this way.
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

    // MARK: - Render-level: the actual call site enforces the gate

    func test_connectButton_forUnacceptedServer_doesNotStartConnectionBeforeConsent() throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Test Server",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.invalid/mcp")!, headers: [:]),
            dataDisclosure: "Test disclosure."
        )
        let registry = ToolRegistry()
        let view = ConnectedServicesView(toolRegistry: registry, catalog: [descriptor], userDefaults: userDefaults)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: "connected-service-connect-\(descriptor.id.uuidString)")
            .button()
            .tap()

        // `coordinator.connect(_:)` synchronously flips `snapshot.isBusy`
        // (disabling this exact button) before its Task ever dispatches —
        // so "still enabled right after the tap" proves no connection
        // attempt fired; the consent dialog gate must have intercepted it
        // instead (`pendingConnect = descriptor`, not `coordinator.connect`).
        let stillEnabled = try view.inspect()
            .find(viewWithAccessibilityIdentifier: "connected-service-connect-\(descriptor.id.uuidString)")
            .button()
            .isDisabled() == false
        XCTAssertTrue(stillEnabled, "Connect button must stay enabled — no connection may start before consent")
    }
}
