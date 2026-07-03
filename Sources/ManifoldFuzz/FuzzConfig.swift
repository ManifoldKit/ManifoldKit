import Foundation

public enum BackendChoice: String, Sendable, CaseIterable {
    case ollama
    case llama
    case foundation
    case mlx
    /// OpenAI-Chat-Completions-compatible cloud endpoint (OpenRouter, OpenAI,
    /// Together, …) driven via `OpenAIBackend`.
    case openai
    /// Hardware-free `MockInferenceBackend` path. Used by PR-tier CI.
    case mock
    /// Hardware-free `ChaosBackend` path for exercising failure-mode plumbing.
    case chaos
}

public struct FuzzConfig: Sendable {
    public let backend: BackendChoice
    public let minutes: Int?
    public let iterations: Int?
    public let seed: UInt64
    public let modelHint: String?
    public let detectorFilter: Set<String>?
    public let outputDir: URL
    /// **Dead knob (2026-07 inert-code audit, finding #40).** Threaded through
    /// this public initializer but never read by `FuzzRunner`, `SessionFuzzRunner`,
    /// or any detector/sink — the one in-repo call site (`fuzz-chat`) hardcodes
    /// `false`, and there is no CLI flag to set it `true` even if a reader
    /// existed. Kept for source compatibility since `FuzzConfig` is a public
    /// type in the `ManifoldFuzz` library product; slated for removal in the
    /// next breaking-change batch rather than here. Do not add a reader for
    /// this — decide wire-vs-remove before relying on it.
    public let calibrate: Bool
    public let quiet: Bool
    /// When `true`, the harness drives multi-turn scripts through
    /// ``SessionFuzzRunner`` instead of the single-turn ``FuzzRunner``.
    /// Additive today — the single-turn path is unchanged.
    public let sessionScripts: Bool
    /// Named corpus subset. Defaults to `.full`. PR-tier CI passes `.smoke`
    /// for a deterministic, backend-agnostic seed list.
    public let corpusSubset: Corpus.Subset
    /// When `true`, the runner injects `SyntheticToolset` into every iteration so
    /// `ToolCallValidityDetector` has invariants to check against. Pairs with the
    /// `--tools` CLI flag.
    public let tools: Bool
    /// Number of process-level workers requested by the campaign front-end.
    /// `FuzzRunner` itself remains single-worker; orchestration lives at the CLI
    /// boundary so backend instances, RNG state, reporters, and sinks stay isolated.
    public let workers: Int

    public init(
        backend: BackendChoice = .ollama,
        minutes: Int? = nil,
        iterations: Int? = nil,
        seed: UInt64 = UInt64.random(in: 0...UInt64.max),
        modelHint: String? = nil,
        detectorFilter: Set<String>? = nil,
        outputDir: URL = URL(fileURLWithPath: "tmp/fuzz", isDirectory: true),
        calibrate: Bool = false,
        quiet: Bool = false,
        sessionScripts: Bool = false,
        corpusSubset: Corpus.Subset = .full,
        tools: Bool = false,
        workers: Int = 1
    ) {
        self.backend = backend
        self.minutes = minutes
        self.iterations = iterations
        self.seed = seed
        self.modelHint = modelHint
        self.detectorFilter = detectorFilter
        self.outputDir = outputDir
        self.calibrate = calibrate
        self.quiet = quiet
        self.sessionScripts = sessionScripts
        self.corpusSubset = corpusSubset
        self.tools = tools
        self.workers = workers
    }
}
