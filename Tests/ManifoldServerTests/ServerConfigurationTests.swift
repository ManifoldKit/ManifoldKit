#if Server
@testable import ManifoldServer
import ManifoldInference
import ManifoldTestSupport
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import XCTest

final class ServerConfigurationTests: XCTestCase {
    func testDefaultsAreCISafeAndLocalOnly() {
        let configuration = ServerConfiguration()

        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.port, 8080)
        XCTAssertNil(configuration.apiKey)
        XCTAssertEqual(configuration.parallelSlots, 1)
        XCTAssertFalse(configuration.unsafeCORS)
        XCTAssertNil(configuration.corsOrigin)
        XCTAssertFalse(configuration.metricsEnabled)
    }

    func testCustomValuesArePreserved() {
        let configuration = ServerConfiguration(
            host: "0.0.0.0",
            port: 9090,
            apiKey: "test-key",
            parallelSlots: 4,
            unsafeCORS: true,
            corsOrigin: "https://example.test",
            metricsEnabled: true
        )

        XCTAssertEqual(configuration.host, "0.0.0.0")
        XCTAssertEqual(configuration.port, 9090)
        XCTAssertEqual(configuration.apiKey, "test-key")
        XCTAssertEqual(configuration.parallelSlots, 4)
        XCTAssertTrue(configuration.unsafeCORS)
        XCTAssertEqual(configuration.corsOrigin, "https://example.test")
        XCTAssertTrue(configuration.metricsEnabled)
    }

    // MARK: - Per-instance body-size limit (inert-config finding: enforcement
    // previously always read ManifoldConfiguration.shared, so a caller-supplied
    // ServerConfiguration.maxServerRequestBodyBytes had no effect).

    func testInstanceMaxServerRequestBodyBytesIsEnforced() async throws {
        let padding = String(repeating: "x", count: 512)
        let request = ChatCompletionRequest(
            model: "fake-model",
            messages: [ChatCompletionMessage(role: .user, content: padding)]
        )
        let body = ByteBuffer(bytes: try JSONEncoder().encode(request))

        // Same request against two ServerApp instances that differ only in
        // the per-instance limit: the tight one must reject, the roomy one
        // must accept. This fails if enforcement reads the global default
        // (4 MB) instead of the instance configuration.
        let tightApp = ServerApp(
            configuration: ServerConfiguration(maxServerRequestBodyBytes: 64),
            backendProvider: FakeServerBackendProvider(backend: MockInferenceBackend()),
            adapter: FakeChatCompletionsAdapter()
        ).makeApplication()
        try await tightApp.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertNotEqual(response.status, .ok, "a body larger than the instance limit must be rejected")
            }
        }

        let roomyApp = ServerApp(
            configuration: ServerConfiguration(maxServerRequestBodyBytes: 1024 * 1024),
            backendProvider: FakeServerBackendProvider(backend: MockInferenceBackend()),
            adapter: FakeChatCompletionsAdapter()
        ).makeApplication()
        try await roomyApp.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok, "the same body under the instance limit must be accepted")
            }
        }
    }
}

#endif
