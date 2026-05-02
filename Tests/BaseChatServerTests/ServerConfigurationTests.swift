@testable import BaseChatServerCore
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
}
