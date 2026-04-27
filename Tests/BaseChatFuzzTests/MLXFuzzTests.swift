#if MLX
import XCTest
import BaseChatFuzz
import BaseChatFuzzBackends
import BaseChatTestSupport

final class MLXFuzzTests: XCTestCase {

    private enum EnvironmentKeys {
        static let minutes = "BASECHAT_FUZZ_MINUTES"
        static let iterations = "BASECHAT_FUZZ_ITERATIONS"
        static let seed = "BASECHAT_FUZZ_SEED"
        static let detector = "BASECHAT_FUZZ_DETECTOR"
        static let quiet = "BASECHAT_FUZZ_QUIET"
        static let sessionScripts = "BASECHAT_FUZZ_SESSION_SCRIPTS"
        static let corpusSubset = "BASECHAT_FUZZ_CORPUS_SUBSET"
        static let tools = "BASECHAT_FUZZ_TOOLS"
        static let model = "MLX_TEST_MODEL"
    }

    private struct ConfigurationError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private var outputDir: URL!

    private static func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: #file)
        while dir.path != "/" {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    override func setUp() async throws {
        try await super.setUp()
        outputDir = Self.repoRoot().appendingPathComponent("tmp/fuzz", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )
    }

    private func skipUnlessHardwareReady(environment: [String: String]) throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "MLXBackend requires Apple Silicon (arm64)")
        try XCTSkipUnless(HardwareRequirements.hasMetalDevice,
                          "MLXBackend requires a Metal GPU device (unavailable in simulator)")
        guard HardwareRequirements.findMLXModelDirectory(environment: environment) != nil else {
            throw XCTSkip(
                "No MLX model found in ~/Documents/Models/. "
                    + "Set MLX_TEST_MODEL=<name> to pin a specific snapshot, or download a safetensors model to run MLX fuzz tests."
            )
        }
    }

    func test_mlxFuzz_runsConfiguredCampaign() async throws {
        let environment = ProcessInfo.processInfo.environment
        try skipUnlessHardwareReady(environment: environment)

        let config = try makeConfig(environment: environment)
        let factory = MLXFuzzFactory(environment: environment)
        let reporter = TerminalReporter(quiet: config.quiet)

        let report: FuzzReport
        if config.sessionScripts {
            let runner = SessionFuzzRunner(config: config, factory: factory)
            report = await runner.run(reporter: reporter)
        } else {
            let runner = FuzzRunner(config: config, factory: factory)
            report = await runner.run(reporter: reporter)
        }

        XCTAssertGreaterThanOrEqual(
            report.totalRuns,
            config.iterations ?? 1,
            "MLX fuzz campaign must complete the configured iteration count, or at least one run for time-based campaigns"
        )
    }

    private func makeConfig(environment: [String: String]) throws -> FuzzConfig {
        let minutes = try parseOptionalInt(EnvironmentKeys.minutes, environment: environment)
        let iterations = try parseOptionalInt(EnvironmentKeys.iterations, environment: environment)
        let seed = try parseOptionalUInt64(EnvironmentKeys.seed, environment: environment) ?? UInt64.random(in: 0...UInt64.max)
        let detectorFilter = parseDetectorFilter(environment[EnvironmentKeys.detector])
        let quiet = try parseOptionalBool(EnvironmentKeys.quiet, environment: environment) ?? false
        let sessionScripts = try parseOptionalBool(EnvironmentKeys.sessionScripts, environment: environment) ?? false
        let tools = try parseOptionalBool(EnvironmentKeys.tools, environment: environment) ?? false
        let corpusSubset = try parseCorpusSubset(environment[EnvironmentKeys.corpusSubset]) ?? .full
        let modelHint = normalizedModelHint(environment[EnvironmentKeys.model])

        let effectiveMinutes = minutes == nil && iterations == nil ? 5 : minutes
        return FuzzConfig(
            backend: .mlx,
            minutes: effectiveMinutes,
            iterations: iterations,
            seed: seed,
            modelHint: modelHint,
            detectorFilter: detectorFilter,
            outputDir: outputDir,
            quiet: quiet,
            sessionScripts: sessionScripts,
            corpusSubset: corpusSubset,
            tools: tools
        )
    }

    private func parseOptionalInt(_ key: String, environment: [String: String]) throws -> Int? {
        guard let raw = environment[key], !raw.isEmpty else { return nil }
        guard let value = Int(raw) else {
            throw ConfigurationError(message: "\(key) must be an integer (got: \(raw))")
        }
        // Reject non-positive durations/iterations so we don't end up with a
        // deadline that fires before the first iteration runs (FuzzRunner's
        // `now >= deadline` check would otherwise terminate the campaign with
        // zero runs, contradicting the "at least one run" assertion below).
        guard value > 0 else {
            throw ConfigurationError(message: "\(key) must be a positive integer (got: \(raw))")
        }
        return value
    }

    private func parseOptionalUInt64(_ key: String, environment: [String: String]) throws -> UInt64? {
        guard let raw = environment[key], !raw.isEmpty else { return nil }
        guard let value = UInt64(raw) else {
            throw ConfigurationError(message: "\(key) must be a UInt64 (got: \(raw))")
        }
        return value
    }

    private func parseOptionalBool(_ key: String, environment: [String: String]) throws -> Bool? {
        guard let raw = environment[key], !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            throw ConfigurationError(message: "\(key) must be one of: 1, 0, true, false, yes, no (got: \(raw))")
        }
    }

    private func parseCorpusSubset(_ raw: String?) throws -> Corpus.Subset? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let subset = Corpus.Subset(rawValue: raw) else {
            throw ConfigurationError(message: "\(EnvironmentKeys.corpusSubset) must be `full` or `smoke` (got: \(raw))")
        }
        return subset
    }

    private func parseDetectorFilter(_ raw: String?) -> Set<String>? {
        guard let raw, !raw.isEmpty else { return nil }
        let detectors = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let filtered = detectors.filter { !$0.isEmpty }
        return filtered.isEmpty ? nil : Set(filtered)
    }

    private func normalizedModelHint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.lowercased() != "all" else { return nil }
        return trimmed
    }
}
#endif
