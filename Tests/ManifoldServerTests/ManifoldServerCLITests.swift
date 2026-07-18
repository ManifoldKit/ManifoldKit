#if Server
@testable import ManifoldServer
import ArgumentParser
import Foundation
import ManifoldInference
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Redirects the process's `stderr` file descriptor to a pipe for the
/// duration of `body`, returning everything written to it. Used to make the
/// `--allow-anonymous` boot-warning duplication (fixed in this PR) provable:
/// `ValidationError`/`fputs` write straight to the real `stderr`, so there is
/// no in-process hook to intercept short of a fd swap.
private func captureStandardError(_ body: () throws -> Void) rethrows -> String {
    fflush(stderr)
    let originalStderrFD = dup(STDERR_FILENO)
    let pipe = Pipe()
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

    defer {
        fflush(stderr)
        dup2(originalStderrFD, STDERR_FILENO)
        close(originalStderrFD)
    }

    try body()

    fflush(stderr)
    try? pipe.fileHandleForWriting.close()
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

final class ManifoldServerCLITests: XCTestCase {
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
        // Include --api-key so auth validation does not fire first.
        XCTAssertThrowsError(try ServerCommandOptions.parse([
            "--api-key", "k",
            "--unsafe-cors",
            "--cors-origin", "https://example.test",
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("--unsafe-cors cannot be combined with --cors-origin"))
        }
    }

    func testRejectsZeroParallel() {
        // ArgumentParser calls validate() internally during parse — the error surfaces there.
        XCTAssertThrowsError(try ServerCommandOptions.parse([
            "--api-key", "k",
            "--parallel", "0",
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("--parallel must be greater than zero"))
        }
    }

    func testRejectsInvalidCORSOrigin() {
        XCTAssertThrowsError(try ServerCommandOptions.parse([
            "--api-key", "k",
            "--cors-origin", "not-a-url",
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("--cors-origin must be a valid URL"))
        }
    }

    // MARK: - H2 auth gates

    func testRejectsUnauthenticatedLoopbackWithoutAllowAnonymous() {
        XCTAssertThrowsError(try ServerCommandOptions.parse([])) { error in
            XCTAssertTrue(
                String(describing: error).contains("--allow-anonymous"),
                "expected allow-anonymous guidance, got \(error)"
            )
        }
    }

    func testAcceptsLoopbackWithAllowAnonymous() throws {
        let options = try ServerCommandOptions.parse(["--allow-anonymous"])
        XCTAssertTrue(options.allowAnonymous)
        XCTAssertNil(options.apiKey)
    }

    func testRejectsNonLoopbackWithoutAPIKey() {
        XCTAssertThrowsError(try ServerCommandOptions.parse([
            "--host", "0.0.0.0",
            "--allow-anonymous",
        ])) { error in
            let text = String(describing: error)
            XCTAssertTrue(
                text.contains("--api-key") || text.contains("loopback"),
                "expected non-loopback auth rejection, got \(error)"
            )
        }
    }

    func testRejectsNonLoopbackWithoutAPIKeyEvenWithoutAllowAnonymous() {
        XCTAssertThrowsError(try ServerCommandOptions.parse([
            "--host", "0.0.0.0",
        ])) { error in
            XCTAssertTrue(
                String(describing: error).contains("--api-key"),
                "expected --api-key requirement for non-loopback, got \(error)"
            )
        }
    }

    func testAcceptsNonLoopbackWithAPIKey() throws {
        let options = try ServerCommandOptions.parse([
            "--host", "0.0.0.0",
            "--api-key", "secret",
        ])
        XCTAssertEqual(options.apiKey, "secret")
        XCTAssertFalse(options.allowAnonymous)
    }

    func testRejectsAllowAnonymousCombinedWithAPIKey() {
        XCTAssertThrowsError(try ServerCommandOptions.parse([
            "--allow-anonymous",
            "--api-key", "secret",
        ])) { error in
            XCTAssertTrue(
                String(describing: error).contains("--allow-anonymous cannot be combined"),
                "got \(error)"
            )
        }
    }

    /// #2312-adjacent: ArgumentParser invokes `ServerCommandOptions.validate()`
    /// once automatically while decoding the parsed `@OptionGroup` (see
    /// `OptionGroup.init(from:)`), before `run()` is ever reached. A prior
    /// version of `ManifoldServerCommand.run()` called `options.validate()`
    /// again explicitly, which duplicated the --allow-anonymous security
    /// warning on every boot. This exercises the full boot sequence (parse +
    /// `buildApp()`, the non-network prefix of `run()`) and asserts the
    /// warning fires exactly once.
    func testAllowAnonymousWarningPrintsExactlyOnceDuringBoot() throws {
        let output = try captureStandardError {
            let parsed = try ManifoldServerCommand.parseAsRoot(["--allow-anonymous"])
            guard let command = parsed as? ManifoldServerCommand else {
                XCTFail("expected ManifoldServerCommand, got \(type(of: parsed))")
                return
            }
            _ = try command.buildApp()
        }

        let marker = "warning: ManifoldServer started with --allow-anonymous"
        let warningCount = output.components(separatedBy: marker).count - 1
        // SABOTAGE: change `1` to `2` to verify this test catches a
        // reintroduced double-validate() call.
        XCTAssertEqual(warningCount, 1, "expected the --allow-anonymous warning exactly once, got \(warningCount) in stderr: \(output)")
    }

    func testLoopbackBindHostClassifier() {
        XCTAssertTrue(ServerCommandOptions.isLoopbackBindHost("127.0.0.1"))
        XCTAssertTrue(ServerCommandOptions.isLoopbackBindHost("localhost"))
        XCTAssertTrue(ServerCommandOptions.isLoopbackBindHost("::1"))
        XCTAssertTrue(ServerCommandOptions.isLoopbackBindHost("127.0.0.2"))
        XCTAssertFalse(ServerCommandOptions.isLoopbackBindHost("0.0.0.0"))
        XCTAssertFalse(ServerCommandOptions.isLoopbackBindHost("192.168.1.1"))
        XCTAssertFalse(ServerCommandOptions.isLoopbackBindHost("::"))
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
            XCTAssertEqual(error as? ServerError, .backendUnavailable("No llama.cpp (GGUF) backend is compiled into this build. Add the manifold-llama companion package (pre-split builds: the Llama trait) — see docs/MIGRATION-0.48.md."))
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
            XCTAssertEqual(error as? ServerError, .notImplemented("Cloud SaaS backend loading is not implemented for ManifoldServer v1; use --backend foundation or --backend ollama (the only two selections that currently load a backend in this build)."))
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

    func testListModelRecordsMarksConfiguredModelCurrent() async throws {
        let provider = TraitAwareServerBackendProvider(
            selection: ServerBackendSelection(backend: .mlx, model: "mlx-community/example", modelPath: "Models/example"),
            compiledBackends: emptyBuild
        )

        let records = try await provider.listModelRecords()

        XCTAssertEqual(records.map(\.id), ["mlx-community/example", "Models/example"])
        XCTAssertEqual(records.map(\.backend), ["mlx", "mlx"])
        XCTAssertEqual(records.map(\.source), ["local_path", "local_path"])
        XCTAssertEqual(records.map(\.current), [false, true])
        XCTAssertEqual(records.map(\.status), ["available", "available"])
    }
}

#endif
