import Foundation
import ManifoldInference

/// Parses adapter-routed cloud streams into generation events.
///
/// `SSECloudBackend` owns backend-protocol orchestration (request lifecycle,
/// retry, metrics, public hooks). This helper owns the routed stream loop:
/// framed transport, stream-limit enforcement, payload decoding, event
/// routing, finalization, and consumer flushing.
package struct CloudRoutedStreamParser: Sendable {
    private let routing: CloudAdapterRouting
    private let limits: SSEStreamLimits
    private let handleUsage: @Sendable ((promptTokens: Int?, completionTokens: Int?)) -> Void

    package init(
        routing: CloudAdapterRouting,
        limits: SSEStreamLimits,
        handleUsage: @escaping @Sendable ((promptTokens: Int?, completionTokens: Int?)) -> Void
    ) {
        self.routing = routing
        self.limits = limits
        self.handleUsage = handleUsage
    }

    package func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let handler = routing.payloadHandler
        let finalizer = routing.streamFinalizer
        let consumer = routing.streamConsumerFactory?()
        var wasThinking = false
        var threwMidStream: Error?
        var limitTracker = RoutedStreamLimitTracker(limits: limits)

        do {
            for await frame in routing.framedTransport.frames(from: bytes) {
                if Task.isCancelled { break }

                try limitTracker.noteFrame(frame)

                let payload = String(data: frame, encoding: .utf8) ?? ""

                // Parse the frame exactly once. Every downstream consumer
                // (the stateful extractor, the stateless handler fallback,
                // and the finalizer) reads off this single parsed structure
                // instead of re-running `JSONSerialization` 8–12× per frame.
                let parsedFrame = ParsedFrame.make(from: payload)

                if !payload.isEmpty {
                    if let consumer {
                        try emitConsumerEvents(
                            from: consumer,
                            frame: parsedFrame,
                            limitTracker: &limitTracker,
                            continuation: continuation
                        )
                    } else {
                        emitHandlerEvents(
                            from: handler,
                            payload: payload,
                            wasThinking: &wasThinking,
                            continuation: continuation
                        )
                    }

                    if let error = handler.extractStreamError(from: payload) {
                        throw error
                    }
                }

                if case .streamComplete(let usage, _) = finalizer.finalize(frame: parsedFrame) {
                    if consumer == nil,
                       let usage,
                       let prompt = usage.promptTokens,
                       let completion = usage.completionTokens {
                        handleUsage((promptTokens: prompt, completionTokens: completion))
                        continuation.yield(.usage(prompt: prompt, completion: completion))
                    }
                    break
                }

                if !payload.isEmpty, handler.isStreamEnd(payload) {
                    break
                }
            }
        } catch {
            threwMidStream = error
        }

        if let consumer {
            let cancelled = Task.isCancelled || threwMidStream != nil
            for event in consumer.finish(cancelled: cancelled) {
                continuation.yield(event)
            }
        }

        if let threwMidStream {
            throw threwMidStream
        }
    }

    private func emitConsumerEvents(
        from consumer: any CloudStreamEventConsumer,
        frame: ParsedFrame,
        limitTracker: inout RoutedStreamLimitTracker,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) throws {
        for event in consumer.consume(frame: frame) {
            if Task.isCancelled { break }
            if case .usage(let prompt, let completion) = event {
                handleUsage((promptTokens: prompt, completionTokens: completion))
            }
            try limitTracker.noteEventYielded()
            continuation.yield(event)
        }
    }

    private func emitHandlerEvents(
        from handler: any SSEPayloadHandler,
        payload: String,
        wasThinking: inout Bool,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) {
        for event in handler.extractEvents(from: payload) {
            switch event {
            case .thinkingToken:
                wasThinking = true
                continuation.yield(event)
            case .thinkingCompleted:
                wasThinking = false
                continuation.yield(event)
            case .token:
                if wasThinking {
                    continuation.yield(.thinkingCompleted)
                    wasThinking = false
                }
                continuation.yield(event)
            default:
                continuation.yield(event)
            }
        }

        if let usage = handler.extractUsage(from: payload) {
            handleUsage(usage)
            if let prompt = usage.promptTokens,
               let completion = usage.completionTokens {
                continuation.yield(.usage(prompt: prompt, completion: completion))
            }
        }
    }
}

private struct RoutedStreamLimitTracker {
    private let limits: SSEStreamLimits
    private var totalBytes = 0
    private var rateWindowStart = ContinuousClock.now
    private var rateWindowCount = 0

    init(limits: SSEStreamLimits) {
        self.limits = limits
    }

    mutating func noteFrame(_ frame: Data) throws {
        if frame.count > limits.maxEventBytes {
            throw SSEStreamError.eventTooLarge(frame.count)
        }

        totalBytes += frame.count + 1
        if totalBytes > limits.maxTotalBytes {
            throw SSEStreamError.streamTooLarge(totalBytes)
        }
    }

    mutating func noteEventYielded() throws {
        let now = ContinuousClock.now
        if now - rateWindowStart >= .seconds(1) {
            rateWindowStart = now
            rateWindowCount = 1
            return
        }

        rateWindowCount += 1
        if rateWindowCount > limits.maxEventsPerSecond {
            throw SSEStreamError.eventRateExceeded(rateWindowCount)
        }
    }
}
