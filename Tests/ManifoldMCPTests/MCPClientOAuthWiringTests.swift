// MCPClientOAuthWiringTests.swift
//
// Two gaps in MCPClient.connect(_:authorization:) found by a public-API gap
// audit (docs/plans/inert-code-audit-2026-07.md):
//
// 1. A descriptor declaring `.oauth(...)` (e.g. MCPCatalog.notion) called with
//    the default `MCPNoAuthorization()` sailed past the existing line-88-ish
//    `.none` guard and failed later on the first 401 with no hint. connect()
//    now throws a clear MCPError up front for that mismatch.
// 2. `MCPOAuthAuthorization`'s own `eventContinuation` (which yields
//    `.authorizationRequired` / `.scopeDowngraded`) defaulted to nil and was
//    never connected by MCPClient, so those two MCPConnectionEvent cases
//    could never be observed. connect() now wires it to the client's own
//    connectionEventContinuation when handed an MCPOAuthAuthorization.
//
// No fixture MCP server is spun up here — both tests exercise connect()
// against a link-local (SSRF-blocked) endpoint the same way
// MCPHardeningTests.test_connectRejectsSSRFBlockedTransportEndpoint does, so
// the assertions are fast and deterministic without mocking a transport.

import Foundation
import XCTest
@testable import ManifoldMCP

final class MCPClientOAuthWiringTests: XCTestCase {

    private func makeOAuthDescriptor() -> MCPAuthorizationDescriptor.OAuthDescriptor {
        MCPAuthorizationDescriptor.OAuthDescriptor(
            clientName: "Test Client",
            scopes: ["tools:read"],
            redirectURI: URL(string: "https://client-\(UUID().uuidString).test/callback")!
        )
    }

    // MARK: - Gap 1: descriptor/.authorization mismatch guard

    func test_connectThrowsWhenDescriptorDeclaresOAuthButCallerLeavesDefaultAuthorization() async throws {
        let descriptor = MCPServerDescriptor(
            displayName: "OAuth Server",
            transport: .streamableHTTP(
                endpoint: URL(string: "https://mcp-\(UUID().uuidString).test/mcp")!,
                headers: [:]
            ),
            authorization: .oauth(makeOAuthDescriptor()),
            dataDisclosure: "test"
        )
        let client = MCPClient()

        do {
            // No `authorization:` argument — falls back to the default
            // MCPNoAuthorization(), which the descriptor above does not accept.
            _ = try await client.connect(descriptor)
            XCTFail("Expected connect() to throw for an .oauth descriptor called with the default MCPNoAuthorization")
        } catch let error as MCPError {
            guard case .transportFailure(let message) = error else {
                XCTFail("Expected .transportFailure, got \(error)")
                return
            }
            XCTAssertTrue(
                message.contains("MCPOAuthAuthorization"),
                "Guard message should name MCPOAuthAuthorization as the fix: \(message)"
            )
            XCTAssertTrue(
                message.contains("MCPNoAuthorization"),
                "Guard message should name what was actually passed: \(message)"
            )
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// Sanity check that the new guard doesn't misfire for the pre-existing
    /// legitimate case: a `.none` descriptor authorization (with
    /// `isUnauthenticatedUnsafe: true`) called with the default
    /// `MCPNoAuthorization()`. That combination must still reach further
    /// (here: the SSRF guard on the link-local endpoint), not the new
    /// oauth-mismatch guard.
    func test_connectDoesNotMisfireMismatchGuardForNoneAuthorizationDescriptor() async throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Blocked",
            transport: .streamableHTTP(endpoint: URL(string: "https://169.254.169.254/mcp")!, headers: [:]),
            dataDisclosure: "test",
            isUnauthenticatedUnsafe: true
        )
        let client = MCPClient()

        do {
            _ = try await client.connect(descriptor)
            XCTFail("Expected SSRF rejection")
        } catch let error as MCPError {
            guard case .ssrfBlocked = error else {
                XCTFail("Expected .ssrfBlocked (proving the new oauth-mismatch guard did not intercept this .none-authorization descriptor), got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Gap 2: MCPOAuthAuthorization event continuation wiring

    func test_connectWiresOAuthAuthorizationEventContinuationBeforeAttemptingTransport() async throws {
        let serverID = UUID()
        let blockedEndpoint = URL(string: "https://169.254.169.254/mcp")!
        let oauthDescriptor = makeOAuthDescriptor()

        let authorization = MCPOAuthAuthorization(
            descriptor: oauthDescriptor,
            serverID: serverID,
            resourceURL: blockedEndpoint,
            redirectListener: RedirectListenerStub { url in
                XCTFail("Redirect listener must not be invoked — connect() should fail at the SSRF guard before token acquisition even starts")
                return url
            },
            tokenStore: .inMemory()
        )

        let beforeConnect = await authorization.eventContinuation
        XCTAssertNil(beforeConnect, "Precondition: a freshly constructed MCPOAuthAuthorization has no event continuation wired.")

        let descriptor = MCPServerDescriptor(
            id: serverID,
            displayName: "Blocked OAuth Server",
            transport: .streamableHTTP(endpoint: blockedEndpoint, headers: [:]),
            authorization: .oauth(oauthDescriptor),
            dataDisclosure: "test"
        )
        let client = MCPClient()

        do {
            _ = try await client.connect(descriptor, authorization: authorization)
            XCTFail("Expected SSRF rejection for the link-local endpoint")
        } catch let error as MCPError {
            guard case .ssrfBlocked = error else {
                XCTFail("Expected .ssrfBlocked, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let afterConnect = await authorization.eventContinuation
        XCTAssertNotNil(
            afterConnect,
            "MCPClient.connect(_:authorization:) must wire the MCPOAuthAuthorization's event continuation to " +
            "its own connectionEventContinuation before attempting the transport (i.e. even though the SSRF " +
            "guard rejected this endpoint), so .authorizationRequired/.scopeDowngraded events reach " +
            "MCPClient.connectionEvents instead of being silently dropped."
        )
    }
}

private actor RedirectListenerStub: MCPOAuthRedirectListener {
    private let handler: (URL) -> URL

    init(handler: @escaping (URL) -> URL) {
        self.handler = handler
    }

    func authorize(
        authorizationURL: URL,
        callbackURLScheme: String,
        prefersEphemeralSession: Bool
    ) async throws -> URL {
        _ = callbackURLScheme
        _ = prefersEphemeralSession
        return handler(authorizationURL)
    }
}
