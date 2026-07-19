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
        XCTAssertFalse(configuration.allowAnonymous)
        XCTAssertEqual(configuration.parallelSlots, 1)
        XCTAssertFalse(configuration.unsafeCORS)
        XCTAssertNil(configuration.corsOrigin)
        XCTAssertFalse(configuration.metricsEnabled)

        // #2265: request/idle timeouts and the output-token ceiling are all
        // on by default with generous-but-bounded values — nil would mean
        // "no cap", silently reintroducing the unbounded hang/output hazard.
        XCTAssertEqual(configuration.generationTimeout, .seconds(600))
        XCTAssertEqual(configuration.streamingIdleTimeout, .seconds(60))
        XCTAssertEqual(configuration.maxGenerationOutputTokens, 4096)
    }

    func testCustomValuesArePreserved() {
        let configuration = ServerConfiguration(
            host: "0.0.0.0",
            port: 9090,
            apiKey: "test-key",
            allowAnonymous: true,
            parallelSlots: 4,
            unsafeCORS: true,
            corsOrigin: "https://example.test",
            metricsEnabled: true,
            generationTimeout: .seconds(5),
            streamingIdleTimeout: .seconds(10),
            maxGenerationOutputTokens: 256
        )

        XCTAssertEqual(configuration.host, "0.0.0.0")
        XCTAssertEqual(configuration.port, 9090)
        XCTAssertEqual(configuration.apiKey, "test-key")
        XCTAssertTrue(configuration.allowAnonymous)
        XCTAssertEqual(configuration.parallelSlots, 4)
        XCTAssertTrue(configuration.unsafeCORS)
        XCTAssertEqual(configuration.corsOrigin, "https://example.test")
        XCTAssertTrue(configuration.metricsEnabled)
        XCTAssertEqual(configuration.generationTimeout, .seconds(5))
        XCTAssertEqual(configuration.streamingIdleTimeout, .seconds(10))
        XCTAssertEqual(configuration.maxGenerationOutputTokens, 256)
    }

    func testTimeoutsAndOutputCapCanBeDisabled() {
        let configuration = ServerConfiguration(
            generationTimeout: nil,
            streamingIdleTimeout: nil,
            maxGenerationOutputTokens: nil
        )
        XCTAssertNil(configuration.generationTimeout)
        XCTAssertNil(configuration.streamingIdleTimeout)
        XCTAssertNil(configuration.maxGenerationOutputTokens)
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

    // MARK: - #2314 shared bind-authorization rule
    //
    // resolveBindAuthorization() is the single source of truth both the CLI
    // (ServerCommandOptions.validate) and the library facade
    // (ManifoldServer.serve) evaluate. Each branch is covered here so a
    // regression in the rule fails at the unit level, not only through a live
    // socket. Each guard is sabotage-proven: deleting its branch reroutes the
    // input to .authenticated / .anonymousLoopback and flips the assertion.

    func testBindAuthorization_authenticatedWhenKeyPresent() {
        let config = ServerConfiguration(host: "0.0.0.0", apiKey: "secret")
        XCTAssertEqual(config.resolveBindAuthorization(), .authenticated)
    }

    func testBindAuthorization_keylessNonLoopbackRefused() {
        let config = ServerConfiguration(host: "0.0.0.0")
        guard case .refused(.keylessNonLoopback(let host)) = config.resolveBindAuthorization() else {
            return XCTFail("keyless 0.0.0.0 bind must be refused: \(config.resolveBindAuthorization())")
        }
        XCTAssertEqual(host, "0.0.0.0")
    }

    func testBindAuthorization_keylessLoopbackWithoutOptInRefused() {
        let config = ServerConfiguration(host: "127.0.0.1")
        guard case .refused(.keylessLoopbackWithoutOptIn(let host)) = config.resolveBindAuthorization() else {
            return XCTFail("keyless loopback bind without opt-in must be refused: \(config.resolveBindAuthorization())")
        }
        XCTAssertEqual(host, "127.0.0.1")
    }

    func testBindAuthorization_keylessLoopbackWithOptInAllowedWithWarning() {
        let config = ServerConfiguration(host: "127.0.0.1", allowAnonymous: true)
        XCTAssertEqual(config.resolveBindAuthorization(), .anonymousLoopback)
    }

    func testBindAuthorization_anonymousOnNonLoopbackRefused() {
        let config = ServerConfiguration(host: "0.0.0.0", allowAnonymous: true)
        guard case .refused(.anonymousOnNonLoopback) = config.resolveBindAuthorization() else {
            return XCTFail("allowAnonymous on a non-loopback host must be refused: \(config.resolveBindAuthorization())")
        }
    }

    func testBindAuthorization_apiKeyCombinedWithAnonymousRefused() {
        let config = ServerConfiguration(host: "127.0.0.1", apiKey: "secret", allowAnonymous: true)
        guard case .refused(.apiKeyCombinedWithAnonymous) = config.resolveBindAuthorization() else {
            return XCTFail("apiKey + allowAnonymous must be refused: \(config.resolveBindAuthorization())")
        }
    }
}

#endif
