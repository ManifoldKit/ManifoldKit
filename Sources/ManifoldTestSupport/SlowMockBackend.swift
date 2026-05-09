import Foundation
import ManifoldInference

/// A mock backend that yields tokens with configurable delays, enabling
/// cancellation to be tested mid-stream.
///
/// Shared across test targets via ManifoldTestSupport.
public final class SlowMockBackend: InferenceBackend, @unchecked Sendable {
    private let stateLock = NSLock()
    private var _isModelLoaded = true
    private var _isGenerating = false
    private var _tokensToYield: [String] = []
    private var _delayPerToken: Duration = .milliseconds(50)
    private var _generateCallCount = 0
    private let lifecycle = MockBackendLifecycle()

    /// Number of times `generate(prompt:systemPrompt:config:)` has been invoked.
    ///
    /// Lets tests verify guards that should prevent re-entry into generation
    /// (e.g. `regenerateLastResponse` short-circuiting while `isGenerating`).
    public var generateCallCount: Int {
        withStateLock { _generateCallCount }
    }

    public var isModelLoaded: Bool {
        get { withStateLock { _isModelLoaded } }
        set { withStateLock { _isModelLoaded = newValue } }
    }

    public var isGenerating: Bool {
        get { withStateLock { _isGenerating } }
        set { withStateLock { _isGenerating = newValue } }
    }

    public let capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    public var tokensToYield: [String] {
        get { withStateLock { _tokensToYield } }
        set { withStateLock { _tokensToYield = newValue } }
    }

    public var delayPerToken: Duration {
        get { withStateLock { _delayPerToken } }
        set { withStateLock { _delayPerToken = newValue } }
    }

    public init() {}

    deinit {
        cancelGeneration(markModelUnloaded: false)
    }

    /// Convenience initialiser that sets an initial token list and a millisecond delay.
    ///
    /// - Parameters:
    ///   - tokenCount: Number of tokens to pre-populate (formatted as `"token0 "`, `"token1 "`, …).
    ///   - delayMilliseconds: Per-token delay in milliseconds (default: 50).
    public init(tokenCount: Int, delayMilliseconds: Int = 50) {
        tokensToYield = (0..<tokenCount).map { "token\($0) " }
        delayPerToken = .milliseconds(delayMilliseconds)
    }

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        withStateLock { _isModelLoaded = true }
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        let (tokens, delay) = withStateLock {
            _isGenerating = true
            _generateCallCount += 1
            return (_tokensToYield, _delayPerToken)
        }

        return lifecycle.makeStream(
            onFinish: { [weak self] in
                self?.withStateLock { self?._isGenerating = false }
            },
            body: { continuation in
                for token in tokens {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: delay)
                    if Task.isCancelled { break }
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

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func cancelGeneration(markModelUnloaded: Bool) {
        withStateLock {
            if markModelUnloaded {
                _isModelLoaded = false
            }
            _isGenerating = false
        }
        lifecycle.cancel()
    }
}
