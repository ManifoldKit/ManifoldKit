#if Llama
import XCTest
import BaseChatFuzz
import BaseChatFuzzBackends
import BaseChatTestSupport

final class LlamaFuzzFactoryTests: XCTestCase {

    func test_supportsDeterministicReplay_isTrue() {
        XCTAssertTrue(
            LlamaFuzzFactory().supportsDeterministicReplay,
            "Llama is deterministic with seed + temperature=0; promotion threshold defaults are safe"
        )
    }

    private func skipUnlessHardwareReady() throws -> URL {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon (arm64)")
        try XCTSkipUnless(HardwareRequirements.hasMetalDevice,
                          "LlamaBackend requires a Metal GPU device (unavailable in simulator)")
        guard let found = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip(
                "No GGUF model found in ~/Documents/Models/. "
                    + "Download a GGUF model (e.g. via the demo app) to run Llama fuzz tests."
            )
        }
        return found
    }

    private func makeTempOutputDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llama-fuzz-factory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_makeHandle_returnsLoadedBackend() async throws {
        let modelURL = try skipUnlessHardwareReady()
        let factory = LlamaFuzzFactory()
        let handle = try await factory.makeHandle()
        defer { Task { await factory.teardown() } }

        XCTAssertTrue(handle.backend.isModelLoaded,
                      "factory must pre-load the backend so the runner's first generate() succeeds")
        XCTAssertEqual(handle.backendName, "llama")
        XCTAssertEqual(handle.modelId, modelURL.lastPathComponent)
        XCTAssertEqual(handle.modelURL, modelURL)
        XCTAssertNil(
            handle.templateMarkers,
            "Llama relies on InferenceService for prompt formatting — the factory leaves template markers unset"
        )
    }

    func test_factoryDrivesOneIterationThroughRunner() async throws {
        _ = try skipUnlessHardwareReady()
        let outputDir = try makeTempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let config = FuzzConfig(
            backend: .llama,
            iterations: 1,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            corpusSubset: .smoke
        )
        let factory = LlamaFuzzFactory()
        let runner = FuzzRunner(config: config, factory: factory)
        let report = await runner.run(reporter: TerminalReporter(quiet: true))
        await factory.teardown()

        XCTAssertGreaterThanOrEqual(
            report.totalRuns, 1,
            "Llama fuzz campaign must complete at least 1 iteration against the installed GGUF"
        )
    }
}
#endif
