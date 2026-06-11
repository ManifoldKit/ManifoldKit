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
        let connectionGuardBox = StrongBox<ConnectAddressPinningDelegate>()
        do {
            try await context.validateEndpoint()

            let (bytes, connectionGuard) = try await openConnection(streamBox: streamBox)
            connectionGuardBox.value = connectionGuard

            await MainActor.run { streamBox.value?.setPhase(.streaming) }
            try await context.streamParser(bytes, continuation)

            await MainActor.run { streamBox.value?.setPhase(.done) }
            continuation.finish()
        } catch {
            streamError = error
            // A connection that rebinds to a private address mid-stream is
            // cancelled by the guard's metrics hook; surface it as a blocked
            // address rather than a silent finish.
            if let blocked = connectionGuardBox.value?.blockedConnectedURL {
                let blockError = CloudBackendError.blockedAddress(
                    "Connection to \(blocked.host ?? "endpoint") rebound to a private/reserved address mid-stream — blocked"
                )
                streamError = blockError
                Log.network.error("\(context.currentBackendName()) stream blocked: DNS rebinding to private address mid-stream")
                await MainActor.run { streamBox.value?.setPhase(.failed(blockError.localizedDescription)) }
                continuation.finish(throwing: blockError)
            } else if error is CancellationError || Task.isCancelled {
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
    ) async throws -> (URLSession.AsyncBytes, ConnectAddressPinningDelegate) {
        let retryCounter = SendableCounter()

        let (bytes, _, connectionGuard) = try await withRetry(
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

            // Connect-time IP pinning closes the DNS-rebinding TOCTOU that the
            // pre-flight `DNSRebindingGuard` (run in `context.validateEndpoint()`)
            // cannot: it inspects the address URLSession actually connected to.
            // A per-task delegate fires `didFinishCollecting` alongside the
            // session-level composite delegate without displacing it.
            let connectionGuard = ConnectAddressPinningDelegate()
            let (bytes, response) = try await context.session.bytes(
                for: attemptRequest,
                delegate: connectionGuard
            )

            // If the connection's metrics already report a private/reserved remote
            // address by the time the response headers arrive, block before
            // consuming any stream bytes. The guard also cancels the task on
            // violation, so a poisoned long-lived SSE connection is torn down and
            // surfaces as a stream error in the parser below.
            if let blocked = connectionGuard.blockedConnectedURL {
                throw CloudBackendError.blockedAddress(
                    "Connection to \(blocked.host ?? "endpoint") resolved to a private/reserved address (DNS rebinding) — blocked"
                )
            }

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
            return (bytes, httpResponse, connectionGuard)
        }

        return (bytes, connectionGuard)
    }
}
