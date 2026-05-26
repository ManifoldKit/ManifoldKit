import Foundation
import ManifoldInference

struct SSEGenerationTaskContext {
    let request: URLRequest
    let eventIDTracker: SSEEventIDTracker
    let retryStrategy: any RetryStrategy
    let retrySleeper: (@Sendable (Duration) async throws -> Void)?
    let session: URLSession
    let streamIdleTimeout: Duration?
    let validateEndpoint: @Sendable () async throws -> Void
    let metricSink: (any InferenceMetricSink)?
    let modelName: String
    let backendName: String
    let maxRetries: Int
    let statusValidator: @Sendable (HTTPURLResponse, URLSession.AsyncBytes) async throws -> Void
    let streamParser: @Sendable (
        URLSession.AsyncBytes,
        AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws -> Void
    let readUsage: @Sendable () -> (promptTokens: Int, completionTokens: Int)?
    let storeTask: @Sendable (Task<Void, Never>) -> Void
    let finishGeneration: @Sendable () -> Void
    let currentBackendName: @Sendable () -> String
}

struct SSEGenerationTaskRunner {
    let context: SSEGenerationTaskContext

    func makeRawStream(
        streamBox: WeakBox<GenerationStream>,
        metricTracker: GenerationMetricTracker
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream<GenerationEvent, Error> { continuation in
            let task = Task {
                await run(
                    continuation: continuation,
                    streamBox: streamBox,
                    metricTracker: metricTracker
                )
            }

            context.storeTask(task)

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func run(
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation,
        streamBox: WeakBox<GenerationStream>,
        metricTracker: GenerationMetricTracker
    ) async {
        defer { context.finishGeneration() }

        var streamError: Error?
        do {
            try await context.validateEndpoint()

            let bytes = try await openConnection(streamBox: streamBox)

            await MainActor.run { streamBox.value?.setPhase(.streaming) }
            try await context.streamParser(bytes, continuation)

            await MainActor.run { streamBox.value?.setPhase(.done) }
            continuation.finish()
        } catch {
            streamError = error
            if error is CancellationError || Task.isCancelled {
                continuation.finish()
            } else {
                Log.network.error("\(context.currentBackendName()) stream error: \(error.localizedDescription, privacy: .private)")
                await MainActor.run { streamBox.value?.setPhase(.failed(error.localizedDescription)) }
                continuation.finish(throwing: error)
            }
        }

        if let sink = context.metricSink {
            SSEGenerationMetrics.record(
                to: sink,
                tracker: metricTracker,
                provider: context.backendName,
                model: context.modelName,
                usage: context.readUsage(),
                errorClass: streamError.map { SSECloudBackend.classifyError($0) }
            )
        }
    }

    private func openConnection(
        streamBox: WeakBox<GenerationStream>
    ) async throws -> URLSession.AsyncBytes {
        let retryCounter = SendableCounter()

        let (bytes, _) = try await withRetry(
            strategy: context.retryStrategy,
            sleeper: context.retrySleeper ?? { try await Task.sleep(for: $0) }
        ) {
            let attempt = retryCounter.incrementAndGet()
            if attempt > 1 {
                await MainActor.run {
                    streamBox.value?.setPhase(.retrying(attempt: attempt - 1, of: context.maxRetries))
                }
            }

            var attemptRequest = context.request
            if let lastID = context.eventIDTracker.lastEventID {
                attemptRequest.setValue(lastID, forHTTPHeaderField: "Last-Event-ID")
            }
            let (bytes, response) = try await context.session.bytes(for: attemptRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                // Carry the rim's `serverError(statusCode: 0, ...)`
                // shape so the eventual user-facing string is the
                // unified "Server returned an unexpected response."
                throw CloudBackendError.networkError(
                    underlying: ManifoldKitError.serverError(
                        statusCode: 0,
                        message: "Malformed server response"
                    )
                )
            }

            try await context.statusValidator(httpResponse, bytes)
            return (bytes, httpResponse)
        }

        return bytes
    }
}
