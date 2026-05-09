import Foundation
import ManifoldInference

/// A test double that models the latency profile of a real streaming backend.
///
/// Unlike ``MockInferenceBackend`` — which yields tokens instantly and masks any
/// UX regression tied to timing — `PerceivedLatencyBackend` reproduces the three
/// latencies a user actually notices:
///
/// 1. **Cold start**: the one-time cost of loading the model on first use.
/// 2. **Time to first token (TTFT)**: the pause between `generate()` being
///    called and the first token arriving on the stream.
/// 3. **Inter-token jitter**: the randomised gap between subsequent tokens,
///    which drives UI batching and scroll stickiness.
///
/// Use this backend in tests that care about responsiveness, typing indicators,
/// load-phase transitions, or streaming UI jank. For functional correctness
/// tests without timing, prefer ``MockInferenceBackend``.
///
/// The backend honours cooperative cancellation: every sleep and every yield
/// checks `Task.isCancelled` before proceeding, so `stopGeneration()` takes
/// effect at the next scheduling point.
public final class PerceivedLatencyBackend: InferenceBackend, @unchecked Sendable {
    private let stateLock = NSLock()
    private var _isModelLoaded = false
    private var _isGenerating = false
    private var _hasPaidColdStart = false
    private let lifecycle = MockBackendLifecycle()

    // Configuration — immutable after init to keep the double simple.
    private let coldStartDelay: Duration
    private let timeToFirstToken: Duration
    private let interTokenJitter: ClosedRange<Duration>
    private let _tokensToYield: [String]
    private let rngSeed: UInt64

    public var isModelLoaded: Bool {
        withStateLock { _isModelLoaded }
    }

    public var isGenerating: Bool {
        withStateLock { _isGenerating }
    }

    public let capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    public var tokensToYield: [String] { _tokensToYield }

    /// Creates a latency-modelling backend.
    ///
    /// - Parameters:
    ///   - coldStartDelay: Paid exactly once on the first `loadModel()` call,
    ///     mimicking on-disk model materialisation.
    ///   - timeToFirstToken: Delay between `generate()` being invoked and the
    ///     first `.token` event arriving on the stream.
    ///   - interTokenJitter: Random range sampled between subsequent tokens.
    ///     A degenerate range (lower == upper) produces constant-rate output.
    ///   - tokensToYield: The token sequence the backend will produce.
    ///   - rngSeed: Seed for the jitter RNG. Default `0xBADC_0FFEE_0DDF00D`
    ///     keeps runs reproducible; pass a different value to vary jitter.
    public init(
        coldStartDelay: Duration = .milliseconds(500),
        timeToFirstToken: Duration = .milliseconds(300),
        interTokenJitter: ClosedRange<Duration> = .milliseconds(20)...(.milliseconds(80)),
        tokensToYield: [String],
        rngSeed: UInt64 = 0xBADC_0FFE_E0DD_F00D
    ) {
        self.coldStartDelay = coldStartDelay
        self.timeToFirstToken = timeToFirstToken
        self.interTokenJitter = interTokenJitter
        self._tokensToYield = tokensToYield
        self.rngSeed = rngSeed
    }

    deinit {
        cancelGeneration(markModelUnloaded: false)
    }

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        let needsColdStart = withStateLock { !_hasPaidColdStart }
        if needsColdStart {
            try await Task.sleep(for: coldStartDelay)
            withStateLock { _hasPaidColdStart = true }
        }
        withStateLock { _isModelLoaded = true }
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        let loaded = withStateLock { _isModelLoaded }
        guard loaded else {
            throw InferenceError.inferenceFailure("No model loaded")
        }

        let tokens = _tokensToYield
        let ttft = timeToFirstToken
        let jitter = interTokenJitter
        let seed = rngSeed

        withStateLock { _isGenerating = true }

        return lifecycle.makeStream(
            onFinish: { [weak self] in
                self?.withStateLock { self?._isGenerating = false }
            },
            body: { continuation in
                // TTFT — the pause the user sees after hitting "send".
                if Task.isCancelled { return }
                try? await Task.sleep(for: ttft)

                var rng = SplitMix64(seed: seed)
                for (index, token) in tokens.enumerated() {
                    if Task.isCancelled { return }
                    if index > 0 {
                        let delay = Self.sample(range: jitter, using: &rng)
                        try? await Task.sleep(for: delay)
                        if Task.isCancelled { return }
                    }
                    continuation.yield(.token(token))
                }
            }
        )
    }

    public func stopGeneration() {
        cancelGeneration(markModelUnloaded: false)
    }

    public func unloadModel() {
        cancelGeneration(markModelUnloaded: true)
    }

    // MARK: - Private

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func cancelGeneration(markModelUnloaded: Bool) {
        withStateLock {
            if markModelUnloaded { _isModelLoaded = false }
            _isGenerating = false
        }
        lifecycle.cancel()
    }

    /// Uniformly samples a Duration from an inclusive range.
    ///
    /// Durations are sampled in nanoseconds because `Duration` does not expose
    /// direct arithmetic with a scalar multiplier that would survive across
    /// platforms. Nanoseconds give us sufficient resolution for UI-scale
    /// jitter (microseconds to hundreds of milliseconds).
    private static func sample(range: ClosedRange<Duration>, using rng: inout SplitMix64) -> Duration {
        let lowerNs = nanoseconds(of: range.lowerBound)
        let upperNs = nanoseconds(of: range.upperBound)
        if upperNs <= lowerNs { return .nanoseconds(lowerNs) }
        let span = UInt64(upperNs - lowerNs)
        let offset = Int64(rng.next() % (span + 1))
        return .nanoseconds(lowerNs + offset)
    }

    private static func nanoseconds(of duration: Duration) -> Int64 {
        let comps = duration.components
        // `seconds` is Int64, `attoseconds` is Int64 with 1e-18 resolution.
        // 1 ns = 1e9 attoseconds.
        return comps.seconds * 1_000_000_000 + comps.attoseconds / 1_000_000_000
    }
}

// MARK: - Deterministic RNG

/// Tiny splitmix64 PRNG used so jitter is reproducible across test runs.
///
/// We avoid `SystemRandomNumberGenerator` specifically because test timing
/// assertions would otherwise be flaky under load.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // A zero seed produces a zero stream with splitmix64; nudge it.
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
}
