@testable import BaseChatServerCore
@testable import BaseChatServerBackends
import ArgumentParser
import BaseChatInference
import XCTest

final class BaseChatServerCLITests: XCTestCase {
    func testParsesServerOptionsAndBuildsConfiguration() throws {
        let options = try ServerCommandOptions.parse([
            "--host", "0.0.0.0",
            "--port", "9090",
            "--api-key", "test-key",
            "--parallel", "4",
            "--backend", "ollama",
            "--model", "llama3.2",
            "--ollama-base-url", "http://127.0.0.1:11434",
            "--cors-origin", "https://example.test",
            "--metrics",
        ])

        XCTAssertEqual(options.host, "0.0.0.0")
        XCTAssertEqual(options.port, 9090)
        XCTAssertEqual(options.apiKey, "test-key")
        XCTAssertEqual(options.parallel, 4)
        XCTAssertEqual(options.backend, .ollama)
        XCTAssertEqual(options.model, "llama3.2")
        XCTAssertEqual(options.ollamaBaseURL, "http://127.0.0.1:11434")
        XCTAssertTrue(options.metrics)

        let configuration = options.serverConfiguration()
        XCTAssertEqual(configuration.host, "0.0.0.0")
        XCTAssertEqual(configuration.port, 9090)
        XCTAssertEqual(configuration.apiKey, "test-key")
        XCTAssertEqual(configuration.parallelSlots, 4)
        XCTAssertEqual(configuration.corsOrigin, "https://example.test")
        XCTAssertTrue(configuration.metricsEnabled)
    }

    func testRejectsInvalidPort() {
        XCTAssertThrowsError(try ServerCommandOptions.parse(["--port", "70000"])) { error in
            XCTAssertTrue(String(describing: error).contains("--port must be between 1 and 65535"))
        }
    }

    func testRejectsUnsafeCORSWithSpecificOrigin() {
        XCTAssertThrowsError(try ServerCommandOptions.parse(["--unsafe-cors", "--cors-origin", "https://example.test"])) { error in
            XCTAssertTrue(String(describing: error).contains("--unsafe-cors cannot be combined with --cors-origin"))
        }
    }
}

final class TraitAwareServerBackendProviderTests: XCTestCase {
    private let emptyBuild = CompiledBackends(
        buildProfile: .offline,
        traits: [],
        localModelTypes: [],
        cloudProviders: []
    )

    func testUnavailableTraitReportsMachineTestableError() {
        let selection = ServerBackendSelection(backend: .llama, modelPath: "model.gguf")

        XCTAssertThrowsError(try selection.validate(compiledBackends: emptyBuild)) { error in
            XCTAssertEqual(error as? ServerError, .backendUnavailable("GGUF models require the Llama trait in this build."))
        }
    }

    func testLlamaRequiresModelPathWhenTraitIsAvailable() {
        let llamaBuild = CompiledBackends(
            buildProfile: .offline,
            traits: [.llama],
            localModelTypes: [.gguf],
            cloudProviders: []
        )
        let selection = ServerBackendSelection(backend: .llama)

        XCTAssertThrowsError(try selection.validate(compiledBackends: llamaBuild)) { error in
            XCTAssertEqual(error as? ServerError, .invalidConfiguration("Llama backend requires --model-path pointing to a .gguf file."))
        }
    }

    func testOllamaSelectionValidatesWithoutNetwork() throws {
        let ollamaBuild = CompiledBackends(
            buildProfile: .selfHosted,
            traits: [.ollama],
            localModelTypes: [],
            cloudProviders: [.ollama]
        )
        let selection = ServerBackendSelection(
            backend: .ollama,
            model: "llama3.2",
            ollamaBaseURL: "http://localhost:11434"
        )

        XCTAssertNoThrow(try selection.validate(compiledBackends: ollamaBuild))
    }

    func testCloudBackendReturnsNotImplementedWithoutNetwork() async {
        let provider = TraitAwareServerBackendProvider(
            selection: ServerBackendSelection(backend: .cloud),
            compiledBackends: emptyBuild
        )

        do {
            _ = try await provider.backend(for: ServerBackendRequest())
            XCTFail("Expected cloud backend to be deferred for v1")
        } catch {
            XCTAssertEqual(error as? ServerError, .notImplemented("Cloud SaaS backend loading is not implemented for BaseChatServer v1; use mlx, llama, foundation, or ollama."))
        }
    }

    func testListModelsUsesConfiguredIdentifiersOnly() async throws {
        let provider = TraitAwareServerBackendProvider(
            selection: ServerBackendSelection(backend: .mlx, model: "mlx-community/example", modelPath: "Models/example"),
            compiledBackends: emptyBuild
        )

        let models = try await provider.listModels()
        XCTAssertEqual(models, ["mlx-community/example", "Models/example"])
    }
}
