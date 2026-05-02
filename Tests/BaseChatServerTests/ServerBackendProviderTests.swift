#if Server
@testable import BaseChatServer
import BaseChatTestSupport
import XCTest

final class ServerBackendProviderTests: XCTestCase {
    func testUnavailableProviderListsNoModels() async throws {
        let provider = UnavailableServerBackendProvider()

        let models = try await provider.listModels()

        XCTAssertEqual(models, [])
    }

    func testUnavailableProviderThrowsBackendUnavailable() async {
        let provider = UnavailableServerBackendProvider()

        do {
            _ = try await provider.backend(for: ServerBackendRequest(model: "missing-model"))
            XCTFail("Expected backend lookup to throw")
        } catch let error as ServerError {
            XCTAssertEqual(error, .backendUnavailable("No server backend has been configured yet."))
            XCTAssertEqual(error.description, "No server backend has been configured yet.")
        } catch {
            XCTFail("Expected ServerError.backendUnavailable, got \(error)")
        }
    }

    func testFakeProviderRecordsRequestsAndReturnsBackend() async throws {
        let backend = MockInferenceBackend()
        let provider = FakeServerBackendProvider(models: ["alpha", "beta"], backend: backend)

        let models = try await provider.listModels()
        let resolved = try await provider.backend(for: ServerBackendRequest(model: "beta"))

        XCTAssertEqual(models, ["alpha", "beta"])
        XCTAssertTrue(resolved is MockInferenceBackend)
        XCTAssertEqual(provider.listModelsCallCount, 1)
        XCTAssertEqual(provider.backendRequests, [ServerBackendRequest(model: "beta")])
    }
}

#endif
