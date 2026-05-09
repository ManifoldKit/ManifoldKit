import Foundation
import ManifoldInference

/// A minimal ``InferenceBackend`` + ``LoadProgressReporting`` stub for contract tests.
///
/// Calls the installed handler with configurable progress values during `loadModel`.
/// Does not perform real inference — use `MockInferenceBackend` when generation is needed.
public final class MockLoadProgressBackend: InferenceBackend, LoadProgressReporting, @unchecked Sendable {

    // MARK: - InferenceBackend

    public var isModelLoaded: Bool = false
    public var isGenerating: Bool = false
    public var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    // MARK: - Configuration

    /// Progress values the handler will be called with during `loadModel`, in order.
    public var progressValuesToEmit: [Double]

    // MARK: - Tracking

    /// Recorded values delivered to the handler during the most recent `loadModel` call.
    public private(set) var deliveredValues: [Double] = []

    // MARK: - Private

    private let lock = NSLock()
    private var _handler: (@Sendable (Double) async -> Void)?

    // MARK: - Init

    public init(progressValuesToEmit: [Double] = [0.0, 0.5, 1.0]) {
        self.progressValuesToEmit = progressValuesToEmit
    }

    // MARK: - LoadProgressReporting

    public func setLoadProgressHandler(_ handler: (@Sendable (Double) async -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        _handler = handler
    }

    // MARK: - InferenceBackend methods

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        let handler = lock.withLock { _handler }
        deliveredValues = []
        for value in progressValuesToEmit {
            deliveredValues.append(value)
            await handler?(value)
        }
        isModelLoaded = true
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        guard isModelLoaded else { throw InferenceError.inferenceFailure("No model loaded") }
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    public func stopGeneration() { isGenerating = false }

    public func unloadModel() {
        isModelLoaded = false
        isGenerating = false
        lock.withLock { _handler = nil }
    }
}
