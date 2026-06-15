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
    /// When `true`, the runner holds the stream phase at
    /// ``GenerationStream/Phase/loading`` after the connection succeeds and only
    /// transitions to ``GenerationStream/Phase/streaming`` once the first event
    /// is yielded by the parser. See ``SSECloudBackend/signalsLoadingUntilFirstToken``.
    let signalsLoadingUntilFirstToken: Bool
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

            if context.signalsLoadingUntilFirstToken {
                // LAN backends (Ollama) can sit on an open `200 OK` connection
                // for minutes while the server loads the model into VRAM and
                // prefills the prompt — no token has arrived yet, so reporting
                // `.streaming` here is a lie. Hold `.loading` and let the parser
                // flip to `.streaming` on the first yielded event below.
                await MainActor.run { streamBox.value?.setPhase(.loading) }
                try await parseAndSignalFirstToken(
                    bytes: bytes,
                    streamBox: streamBox,
                    continuation: continuation
                )
            } else {
                await MainActor.run { streamBox.value?.setPhase(.streaming) }
                try await context.streamParser(bytes, continuation)
            }

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
            // Compute cost in ManifoldCloudCore where InferenceCostEstimator lives,
            // then pass the pre-resolved values to the ManifoldInference record helper.
            let usage = context.readUsage()
            let promptTokens = usage?.promptTokens ?? 0
            let completionTokens = usage?.completionTokens ?? 0
            let (costUSD, isApprox) = InferenceCostEstimator.estimatedCost(
                provider: context.backendName,
                model: context.modelName,
                promptTokens: promptTokens,
                completionTokens: completionTokens
            )
            SSEGenerationMetrics.record(
                to: sink,
                tracker: metricTracker,
                provider: context.backendName,
                model: context.modelName,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                estimatedCostUSD: costUSD,
                isCostApproximate: isApprox,
                costTableDate: InferenceCostEstimator.costTableDate,
                errorClass: streamError.map { SSECloudBackend.classifyError($0) }
            )
        }
    }

    /// Drives the parser while holding the stream at `.loading`, flipping to
    /// `.streaming` the moment the first event is yielded.
    ///
    /// The parser yields into an intermediate stream that this method drains and
    /// forwards to the real `continuation`. The drain loop is the same async
    /// context as the parser (`async let` + awaited below), so no side task is
    /// leaked: when the parser finishes, throws, or the downstream consumer
    /// terminates the outer stream (cancelling this whole `run` task), the
    /// intermediate stream finishes and the loop exits. Cancellation propagates
    /// because the parser task is the cancelled `run` task itself.
    private func parseAndSignalFirstToken(
        bytes: URLSession.AsyncBytes,
        streamBox: WeakBox<GenerationStream>,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { innerContinuation in
            let parseTask = Task {
                do {
                    try await context.streamParser(bytes, innerContinuation)
                    innerContinuation.finish()
                } catch {
                    innerContinuation.finish(throwing: error)
                }
            }
            innerContinuation.onTermination = { @Sendable _ in parseTask.cancel() }
        }

        var sawFirstEvent = false
        do {
            for try await event in inner {
                if !sawFirstEvent {
                    sawFirstEvent = true
                    await MainActor.run { streamBox.value?.setPhase(.streaming) }
                }
                continuation.yield(event)
            }
        } catch {
            // If the connection produced zero events (pure load-stall that then
            // failed), the phase is still `.loading`; let the caller's catch set
            // `.failed`. Re-throw so retry/error handling in `run` runs.
            throw error
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
