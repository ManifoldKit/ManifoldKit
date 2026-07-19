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

    // MARK: - #2313 per-request model routing

    /// The pre-#2313 provider returned its cached backend before `request.model`
    /// was consulted, so the first request pinned the model and later selections
    /// were silently ignored. This asserts the cache is keyed by resolved model
    /// ID: a repeated model hits the cache; a changed model reloads and never
    /// returns the previous backend under the new name.
    ///
    /// Sabotage-evidence: restore the old `if let cached = cachedBackend {
    /// return cached }` early return and the `"beta"` request returns the cached
    /// `"alpha"` backend — flipping the `third === backendBeta`,
    /// `loadedAfterBeta == "beta"`, and `recorded == ["alpha", "beta"]`
    /// assertions.
    func testProviderReloadsWhenRequestedModelChanges() async throws {
        let backendAlpha = MockInferenceBackend()
        let backendBeta = MockInferenceBackend()
        let loads = LoaderCallLog()

        let provider = TraitAwareServerBackendProvider(
            selection: ServerBackendSelection(backend: .ollama, ollamaBaseURL: "http://localhost:11434"),
            backendLoaderForTesting: { request in
                await loads.record(request.model)
                return request.model == "beta" ? backendBeta : backendAlpha
            }
        )

        let first = try await provider.backend(for: ServerBackendRequest(model: "alpha"))
        let loadedAfterAlpha = await provider.loadedModelID
        let secondAlpha = try await provider.backend(for: ServerBackendRequest(model: "alpha"))
        let third = try await provider.backend(for: ServerBackendRequest(model: "beta"))
        let loadedAfterBeta = await provider.loadedModelID
        let recorded = await loads.models

        XCTAssertTrue((first as AnyObject) === (backendAlpha as AnyObject), "first request must route to its own model")
        XCTAssertEqual(loadedAfterAlpha, "alpha")
        XCTAssertTrue((secondAlpha as AnyObject) === (backendAlpha as AnyObject), "a repeated model must be served from cache")
        XCTAssertTrue((third as AnyObject) === (backendBeta as AnyObject), "a changed model must reload — never return the cached backend under a new name (#2313)")
        XCTAssertEqual(loadedAfterBeta, "beta")
        // Two loads, not three: the repeated "alpha" was a cache hit.
        XCTAssertEqual(recorded, ["alpha", "beta"])
        // Switching models must NOT unloadModel() the backend we left. The
        // cached instance is shared across concurrent requests and
        // unloadModel() chains to stopGeneration() (backend-wide), so unloading
        // on switch would cancel a sibling client's in-flight generation under
        // parallelSlots > 1. Reverting to `previous.unloadModel()` on the
        // reload path flips this assertion.
        XCTAssertEqual(backendAlpha.unloadCallCount, 0, "the switched-away backend must not be torn down (could hold a concurrent generation)")
    }
}

/// Records the models a `backendLoaderForTesting` was invoked for, so a test can
/// distinguish a cache hit (loader not called) from a reload.
private actor LoaderCallLog {
    private(set) var models: [String] = []
    func record(_ model: String?) { models.append(model ?? "<nil>") }
}

#endif
