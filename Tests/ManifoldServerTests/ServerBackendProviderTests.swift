#if Server
@testable import ManifoldServer
import ManifoldTestSupport
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
        let modelRecords = try await provider.listModelRecords()
        let resolved = try await provider.backend(for: ServerBackendRequest(model: "beta"))

        XCTAssertEqual(models, ["alpha", "beta"])
        XCTAssertEqual(modelRecords.map(\.id), ["alpha", "beta"])
        XCTAssertEqual(modelRecords.map(\.status), ["available", "available"])
        XCTAssertTrue(resolved is MockInferenceBackend)
        XCTAssertEqual(provider.listModelsCallCount, 2)
        XCTAssertEqual(provider.backendRequests, [ServerBackendRequest(model: "beta")])
    }

    func testTraitAwareProviderAnnotatesModelRecords() async throws {
        let provider = TraitAwareServerBackendProvider(selection: ServerBackendSelection(
            backend: .ollama,
            model: "llama3",
            ollamaBaseURL: "http://localhost:11434"
        ))

        let records = try await provider.listModelRecords()

        XCTAssertEqual(records, [
            ModelsListResponse.Model(
                id: "llama3",
                status: "available",
                backend: "ollama",
                source: "remote_endpoint",
                current: true
            )
        ])
    }

    func testTraitAwareProviderListsOllamaDefaultModel() async throws {
        let provider = TraitAwareServerBackendProvider(selection: ServerBackendSelection(
            backend: .ollama,
            ollamaBaseURL: "http://localhost:11434"
        ))

        let records = try await provider.listModelRecords()

        XCTAssertEqual(records, [
            ModelsListResponse.Model(
                id: "llama3.2",
                status: "available",
                backend: "ollama",
                source: "remote_endpoint",
                current: true
            )
        ])
    }

    func testTraitAwareProviderMarksMLXModelPathLoadedBeforeModelIdentifier() async throws {
        let provider = TraitAwareServerBackendProvider(
            selection: ServerBackendSelection(
                backend: .mlx,
                model: "mlx-community/example",
                modelPath: "Models/example"
            )
        )

        let modelID = await provider.modelID(for: ServerBackendRequest(model: "request-override"))

        XCTAssertEqual(modelID, "Models/example")
    }

    func testTraitAwareProviderListsLoadedOverrideBeforeConfiguredModels() async throws {
        let provider = TraitAwareServerBackendProvider(
            selection: ServerBackendSelection(
                backend: .ollama,
                ollamaBaseURL: "http://localhost:11434"
            ),
            loadedModelID: "llama3"
        )

        let records = try await provider.listModelRecords()

        XCTAssertEqual(records.map(\.id), ["llama3", "llama3.2"])
        XCTAssertEqual(records.map(\.status), ["loaded", "available"])
    }
}

#endif
