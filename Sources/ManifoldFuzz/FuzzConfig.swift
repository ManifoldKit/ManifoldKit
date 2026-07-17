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
    /// Per-iteration wall-clock bound on generation, in seconds. For the
    /// OpenAI cloud backend this is additionally enforced at the HTTP
    /// transport layer (`OpenAIFuzzFactory.requestTimeout`, a finer-grained
    /// idle timeout that resets per byte received); for every backend it is
    /// also enforced here as a coarser whole-generation cap via
    /// `GenerationTimeout`, which is what actually bounds local backends
    /// (Ollama, Foundation, mock, chaos) that previously had no per-request
    /// timeout at all. Default 90s matches the CLI's `--request-timeout`
    /// default and stays above `TimeoutDetector`'s 60s flag threshold, so a
    /// slow-but-completing run is still flagged as an anomaly rather than
    /// hard-cut at the same boundary.
    public let requestTimeout: TimeInterval

    public init(
        backend: BackendChoice = .ollama,
        minutes: Int? = nil,
        iterations: Int? = nil,
        seed: UInt64 = UInt64.random(in: 0...UInt64.max),
        modelHint: String? = nil,
        detectorFilter: Set<String>? = nil,
        outputDir: URL = URL(fileURLWithPath: "tmp/fuzz", isDirectory: true),
        quiet: Bool = false,
        sessionScripts: Bool = false,
        corpusSubset: Corpus.Subset = .full,
        tools: Bool = false,
        workers: Int = 1,
        requestTimeout: TimeInterval = 90
    ) {
        self.backend = backend
        self.minutes = minutes
        self.iterations = iterations
        self.seed = seed
        self.modelHint = modelHint
        self.detectorFilter = detectorFilter
        self.outputDir = outputDir
        self.quiet = quiet
        self.sessionScripts = sessionScripts
        self.corpusSubset = corpusSubset
        self.tools = tools
        self.workers = workers
        self.requestTimeout = requestTimeout
    }
}
