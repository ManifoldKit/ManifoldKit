import XCTest
import Foundation
@testable import ManifoldCloudCore
@testable import ManifoldCloudSaaS
@testable import ManifoldInference

/// Tests for ``KeychainTokenProvider`` and ``SecondaryBackendBuilder`` — the
/// CloudCore-level seam (issue #1846) that lets callers build a secondary,
/// independently-credentialed cloud backend from a saved endpoint record + a
/// rotating ``TokenProvider``.
///
/// `KeychainTokenProvider` is exercised through its injected retrieval closure
/// (the production seam) so the read-each-call behavior is deterministic and
/// never touches the real Keychain.
///
/// XCTest (not Swift Testing) because this file links into the merged-filter
/// `ManifoldBackendsTests` process alongside XCTest suites — see
/// `SwiftTestingAuditTest` / issue #681.
final class SecondaryBackendBuilderTests: XCTestCase {

    // MARK: - KeychainTokenProvider

    func test_keychainTokenProvider_readsCurrentValueEachCall() async throws {
        // A mutable backing store stands in for the Keychain. The provider must
        // re-read it on every token() call so credential rotation is picked up
        // without a reconfigure.
        final class Box: @unchecked Sendable { var value: String? = "first" }
        let box = Box()
        let account = "rotating-\(UUID().uuidString)"

        let provider = KeychainTokenProvider(keychainAccount: account) { requested in
            XCTAssertEqual(requested, account)
            return box.value
        }

        let first = try await provider.token()
        XCTAssertEqual(first, "first")

        // Rotate the stored secret; the next call must observe the new value.
        box.value = "second"
        let second = try await provider.token()
        XCTAssertEqual(second, "second")
    }

    func test_keychainTokenProvider_missingCredential_throws() async {
        let provider = KeychainTokenProvider(keychainAccount: "absent") { _ in nil }
        do {
            _ = try await provider.token()
            XCTFail("Expected token() to throw for a missing credential")
        } catch {
            XCTAssertTrue(error is CloudBackendError, "Expected CloudBackendError, got \(error)")
        }
    }

    func test_keychainTokenProvider_emptyCredential_throws() async {
        // An empty string is treated as "no credential" rather than a valid
        // empty bearer token that would surface later as an opaque 401.
        let provider = KeychainTokenProvider(keychainAccount: "blank") { _ in "" }
        do {
            _ = try await provider.token()
            XCTFail("Expected token() to throw for an empty credential")
        } catch {
            XCTAssertTrue(error is CloudBackendError, "Expected CloudBackendError, got \(error)")
        }
    }

    // MARK: - SecondaryBackendBuilder

    /// A stand-in TokenProvider for builder wiring tests.
    private struct StaticTokenProvider: TokenProvider {
        let value: String
        func token() async throws -> String { value }
    }

    func test_cloudBackend_claude_returnsConfiguredBackend() throws {
        let endpoint = APIEndpointRecord(
            provider: .claude,
            baseURL: "https://api.anthropic.com",
            modelName: "claude-test-model"
        )

        let built = SecondaryBackendBuilder.cloudBackend(
            for: endpoint,
            tokenProvider: StaticTokenProvider(value: "tok")
        ) { provider in
            XCTAssertEqual(provider, .claude)
            return ClaudeBackend()
        }

        let sse = try XCTUnwrap(built as? SSECloudBackend)
        XCTAssertEqual(sse.baseURL, URL(string: "https://api.anthropic.com"))
        XCTAssertEqual(sse.modelName, "claude-test-model")
    }

    func test_cloudBackend_openAI_returnsConfiguredBackend() throws {
        let endpoint = APIEndpointRecord(
            provider: .openAI,
            baseURL: "https://api.openai.com",
            modelName: "gpt-test"
        )

        let built = SecondaryBackendBuilder.cloudBackend(
            for: endpoint,
            tokenProvider: StaticTokenProvider(value: "tok")
        ) { _ in OpenAIBackend() }

        let sse = try XCTUnwrap(built as? SSECloudBackend)
        XCTAssertEqual(sse.modelName, "gpt-test")
        XCTAssertEqual(sse.baseURL, URL(string: "https://api.openai.com"))
    }

    func test_cloudBackend_ollama_returnsNil() {
        // Ollama authenticates with URL + model, not a bearer token, so the
        // token-provider path does not apply. makeBackend must never be invoked.
        let endpoint = APIEndpointRecord(
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3"
        )

        var madeBackend = false
        let built = SecondaryBackendBuilder.cloudBackend(
            for: endpoint,
            tokenProvider: StaticTokenProvider(value: "tok")
        ) { _ in
            madeBackend = true
            return ClaudeBackend()
        }

        XCTAssertNil(built)
        XCTAssertFalse(madeBackend)
    }

    func test_cloudBackend_lmStudio_returnsNil() {
        let endpoint = APIEndpointRecord(
            provider: .lmStudio,
            baseURL: "http://localhost:1234",
            modelName: "local-model"
        )

        let built = SecondaryBackendBuilder.cloudBackend(
            for: endpoint,
            tokenProvider: StaticTokenProvider(value: "tok")
        ) { _ in ClaudeBackend() }

        XCTAssertNil(built)
    }

    func test_cloudBackend_invalidURL_returnsNil() {
        let endpoint = APIEndpointRecord(
            provider: .claude,
            baseURL: "   ",
            modelName: "m"
        )

        let built = SecondaryBackendBuilder.cloudBackend(
            for: endpoint,
            tokenProvider: StaticTokenProvider(value: "tok")
        ) { _ in ClaudeBackend() }

        XCTAssertNil(built)
    }

    func test_cloudBackend_factoryReturnsNil_returnsNil() {
        let endpoint = APIEndpointRecord(
            provider: .custom,
            baseURL: "https://example.test",
            modelName: "m"
        )

        let built = SecondaryBackendBuilder.cloudBackend(
            for: endpoint,
            tokenProvider: StaticTokenProvider(value: "tok")
        ) { _ in nil }

        XCTAssertNil(built)
    }
}
