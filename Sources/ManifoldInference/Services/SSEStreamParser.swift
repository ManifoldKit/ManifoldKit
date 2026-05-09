import Foundation

/// Configurable caps applied to SSE (and NDJSON) parsing to defend against
/// hostile or misconfigured upstream servers.
///
/// The parser enforces three separate bounds:
///
/// - ``maxEventBytes`` caps the size of a single event payload buffer. A
///   malicious server cannot make the client swallow a 100 MB `data:` line.
/// - ``maxTotalBytes`` caps cumulative bytes across the whole stream. This
///   stops a server that drips just-small-enough events forever.
/// - ``maxEventsPerSecond`` caps the yield rate. A flood of 1-byte events is
///   rejected before it can starve the consumer.
///
/// Defaults (``default``) are intentionally well above any realistic provider
/// throughput — OpenAI, Anthropic, and Ollama all emit events far smaller
/// than 1 MB and well under 5,000 events per second — so legitimate traffic is
/// never throttled.
///
/// ## Tuning
///
/// Most apps never need to change these. Raise a cap only if you observe
/// legitimate traffic failing — for example, a provider that ships a
/// multi-megabyte tool-use result in a single event. Lower a cap when you
/// point a backend at an untrusted endpoint and want to narrow the attack
/// surface further.
///
/// ```swift
/// // App-wide: applies to every SSECloudBackend at launch.
/// ManifoldConfiguration.shared.sseStreamLimits = SSEStreamLimits(
///     maxEventBytes: 500_000,
///     maxTotalBytes: 10_000_000,
///     maxEventsPerSecond: 2_000
/// )
///
/// // Per backend: leaves OpenAI/Anthropic at defaults while tightening an
/// // untrusted CustomEndpoint.
/// let backend = OpenAIBackend(endpoint: untrusted)
/// backend.sseStreamLimits = SSEStreamLimits(
///     maxEventBytes: 64_000,
///     maxTotalBytes: 1_000_000,
///     maxEventsPerSecond: 500
/// )
/// ```
///
/// There is deliberately no "unlimited" option: bounded caps are the point.
public struct SSEStreamLimits: Sendable, Equatable {

    /// Maximum byte size of a single event payload buffer, including bytes
    /// that have not yet reached a newline.
    public var maxEventBytes: Int

    /// Maximum cumulative byte count across the entire stream, counting all
    /// bytes the parser consumes (including control and ignored lines).
    public var maxTotalBytes: Int

    /// Maximum events the parser may yield within a one-second rate window.
    ///
    /// The window is fixed (not sliding): it opens on the first event and
    /// resets once at least one wall-clock second has elapsed. A burst that
    /// exceeds this count within the active window finishes the stream with
    /// ``SSEStreamError/eventRateExceeded(_:)``.
    public var maxEventsPerSecond: Int

    public init(
        maxEventBytes: Int,
        maxTotalBytes: Int,
        maxEventsPerSecond: Int
    ) {
        self.maxEventBytes = maxEventBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxEventsPerSecond = maxEventsPerSecond
    }

    /// Conservative defaults suitable for every mainstream provider.
    ///
    /// - 1 MB per event: large enough for chunked usage payloads and tool
    ///   call metadata, small enough to reject a pathological upstream.
    /// - 50 MB per stream: covers hours of conversation tokens without
    ///   allowing unbounded streams.
    /// - 5,000 events/s: roughly 100x real provider throughput; a healthy
    ///   LLM tops out at a few hundred tokens/s.
    public static let `default` = SSEStreamLimits(
        maxEventBytes: 1_000_000,
        maxTotalBytes: 50_000_000,
        maxEventsPerSecond: 5_000
    )
}

/// Errors thrown by ``SSEStreamParser`` when a stream violates its limits.
///
/// These surface through the existing `AsyncThrowingStream` failure channel
/// exactly like any other parsing error, so backend retry/error UI continues
/// to work unchanged.
public enum SSEStreamError: Error, Equatable, Sendable {
    /// A single event exceeded ``SSEStreamLimits/maxEventBytes``. The
    /// associated value is the observed size in bytes.
    case eventTooLarge(Int)

    /// Cumulative bytes across the stream exceeded
    /// ``SSEStreamLimits/maxTotalBytes``. The associated value is the total
    /// bytes consumed before the limit tripped.
    case streamTooLarge(Int)

    /// More events than ``SSEStreamLimits/maxEventsPerSecond`` were produced
    /// within a single one-second window. The associated value is the event
    /// count observed in that window.
    case eventRateExceeded(Int)
}

/// Parses Server-Sent Events (SSE) from a byte stream.
///
/// SSE format:
/// ```
/// data: {"content": "token"}
///
/// data: [DONE]
/// ```
///
/// Used by both OpenAI-compatible and Claude backends to stream tokens
/// from cloud API responses.
/// Interprets SSE JSON payloads for a specific API format.
///
/// Each cloud backend provides its own implementation to extract tokens,
/// usage, stream-end signals, and errors from the provider's JSON format.
///
/// ## Event-level routing
///
/// ``extractEvents(from:)`` is the primary entry point: it maps one SSE
/// payload to zero or more ``GenerationEvent`` values. This lets a single
/// chunk surface ``GenerationEvent/token(_:)``, ``GenerationEvent/thinkingToken(_:)``,
/// or ``GenerationEvent/thinkingComplete`` as the provider's wire format
/// requires, without forcing the base class to reinterpret a raw string.
///
/// The default implementation wraps the legacy ``extractToken(from:)``
/// result into `[.token(...)]`, so existing conformers keep compiling
/// unchanged. New conformers should implement ``extractEvents(from:)``
/// directly and leave ``extractToken(from:)`` as a no-op.
public protocol SSEPayloadHandler: Sendable {
    /// Extracts a text token from a JSON payload, or `nil` if not a token event.
    ///
    /// - Important: Prefer ``extractEvents(from:)`` for new conformers. This
    ///   method is preserved for backwards compatibility — every shipping
    ///   handler (Ollama, Claude, OpenAI Chat Completions, OpenAI Responses)
    ///   now also implements ``extractEvents(from:)``, but the legacy hook
    ///   stays in the protocol so external SSEPayloadHandler conformers
    ///   continue to compile.
    func extractToken(from payload: String) -> String?

    /// Maps a single SSE JSON payload to zero or more generation events.
    ///
    /// Returning multiple events from one payload lets a handler distinguish
    /// thinking/reasoning deltas from regular text deltas natively. For
    /// lifecycle-style `.thinkingComplete` events that cannot be derived
    /// from a single chunk (e.g. OpenAI's `reasoning_content` → `content`
    /// transition), the `SSECloudBackend` base loop injects the event on
    /// the first non-thinking-token event that follows one or more
    /// thinking-token events, so handlers can stay stateless.
    ///
    /// Handlers that already know they are at a reasoning-block boundary
    /// (e.g. an inline-tag parser using `ThinkingParser`) may emit
    /// ``GenerationEvent/thinkingComplete`` themselves; the base loop's
    /// flag tracking is idempotent and will not duplicate the event.
    ///
    /// The default implementation wraps ``extractToken(from:)`` so existing
    /// handlers continue to work. Override for any handler that needs to
    /// classify thinking vs. text deltas.
    func extractEvents(from payload: String) -> [GenerationEvent]

    /// Extracts token usage from a JSON payload, or `nil` if not a usage event.
    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)?

    /// Returns `true` if the payload signals end of stream.
    func isStreamEnd(_ payload: String) -> Bool

    /// Extracts an error from a JSON payload, or `nil` if not an error event.
    func extractStreamError(from payload: String) -> Error?
}

extension SSEPayloadHandler {
    /// Default implementation that wraps ``extractToken(from:)`` into a
    /// single-element `[.token(...)]` array, preserving the old protocol's
    /// behaviour for handlers that have not yet migrated to event-level
    /// routing.
    public func extractEvents(from payload: String) -> [GenerationEvent] {
        if let token = extractToken(from: payload) {
            return [.token(token)]
        }
        return []
    }
}

/// Thread-safe holder for the last SSE event ID seen in a stream.
/// Passed optionally to ``SSEStreamParser/parse(bytes:limits:eventIDTracker:)``
/// so callers can inject the stored ID as ``Last-Event-ID`` on reconnect.
package final class SSEEventIDTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastEventID: String?

    package init() {}

    /// The last `id:` field value received, or `nil` if none has been seen
    /// or the most recent `id:` field was empty (spec: empty id resets to null).
    package var lastEventID: String? {
        lock.withLock { _lastEventID }
    }

    package func update(_ id: String?) {
        lock.withLock { _lastEventID = id }
    }
}

package struct SSEStreamParser {
    package struct NamedEvent: Sendable, Equatable {
        package let name: String?
        package let data: String
        package let id: String?
    }

    /// Parses an `AsyncSequence` of bytes into an `AsyncThrowingStream` of SSE data lines.
    ///
    /// Yields the payload of each `data:` line (with the prefix stripped).
    /// Stops when the stream ends or when `[DONE]` is received.
    ///
    /// The stream is bounded by the supplied ``SSEStreamLimits``; a violation
    /// is surfaced by finishing the stream with the appropriate
    /// ``SSEStreamError``.
    ///
    /// - Parameters:
    ///   - bytes: The raw byte stream.
    ///   - limits: Caps that defend against hostile upstreams. Defaults to
    ///     `ManifoldConfiguration.shared.sseStreamLimits`.
    ///   - eventIDTracker: Optional tracker updated whenever an `id:` field is
    ///     parsed. Callers pass this to inject `Last-Event-ID` on reconnect.
    package static func parse<S: AsyncSequence & Sendable>(
        bytes: S,
        limits: SSEStreamLimits = ManifoldConfiguration.shared.sseStreamLimits,
        eventIDTracker: SSEEventIDTracker? = nil
    ) -> AsyncThrowingStream<String, Error> where S.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                var byteBuffer = Data()
                var iterator = bytes.makeAsyncIterator()

                // Cumulative bytes consumed across the whole stream.
                var totalBytes = 0

                // Fixed-window rate limiter: the window starts on the first
                // event and resets to "now" whenever at least one second has
                // elapsed. Cheaper than a true sliding window and tight enough
                // for DoS defence — a burst above the cap still trips inside
                // the active window, which is what matters.
                var rateWindowStart = ContinuousClock.now
                var rateWindowCount = 0
                let maxRate = limits.maxEventsPerSecond

                func noteEventYielded() -> SSEStreamError? {
                    let now = ContinuousClock.now
                    if now - rateWindowStart >= .seconds(1) {
                        rateWindowStart = now
                        rateWindowCount = 1
                        return nil
                    }
                    rateWindowCount += 1
                    if rateWindowCount > maxRate {
                        return .eventRateExceeded(rateWindowCount)
                    }
                    return nil
                }

                do {
                    while let byte = try await iterator.next() {
                        if Task.isCancelled { break }

                        totalBytes += 1
                        if totalBytes > limits.maxTotalBytes {
                            throw SSEStreamError.streamTooLarge(totalBytes)
                        }

                        if byte == UInt8(ascii: "\n") {
                            // Decode accumulated bytes as UTF-8.
                            let line: String
                            if let decoded = String(data: byteBuffer, encoding: .utf8) {
                                line = decoded.trimmingCharacters(in: .whitespaces)
                            } else {
                                // Skip lines with invalid UTF-8 rather than crash.
                                Log.network.warning("SSEStreamParser: skipped \(byteBuffer.count)-byte line with invalid UTF-8")
                                byteBuffer.removeAll(keepingCapacity: true)
                                continue
                            }
                            byteBuffer.removeAll(keepingCapacity: true)

                            if line.isEmpty { continue }

                            if line.hasPrefix("data:") {
                                let payload = String(line.dropFirst(5))
                                    .trimmingCharacters(in: .whitespaces)

                                if payload == "[DONE]" {
                                    break
                                }

                                if !payload.isEmpty {
                                    if let rateError = noteEventYielded() {
                                        throw rateError
                                    }
                                    continuation.yield(payload)
                                }
                            } else if line.hasPrefix("id:") {
                                let id = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                                // Per spec, an empty id: field resets the last event ID to null.
                                eventIDTracker?.update(id.isEmpty ? nil : id)
                            }
                            // event:, retry:, and comment lines are still intentionally ignored.
                        } else {
                            byteBuffer.append(byte)
                            if byteBuffer.count > limits.maxEventBytes {
                                throw SSEStreamError.eventTooLarge(byteBuffer.count)
                            }
                        }
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Parses SSE into named events by pairing `event:` + `data:` fields and
    /// emitting on event boundaries (blank line).
    ///
    /// - Important: Multiple `data:` lines in a single event are coalesced
    ///   with `\n` per the SSE specification.
    package static func parseNamed<S: AsyncSequence & Sendable>(
        bytes: S,
        limits: SSEStreamLimits = ManifoldConfiguration.shared.sseStreamLimits,
        eventIDTracker: SSEEventIDTracker? = nil
    ) -> AsyncThrowingStream<NamedEvent, Error> where S.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                var byteBuffer = Data()
                var iterator = bytes.makeAsyncIterator()

                var totalBytes = 0
                var rateWindowStart = ContinuousClock.now
                var rateWindowCount = 0
                let maxRate = limits.maxEventsPerSecond

                var currentEventName: String?
                var currentEventID: String?
                var dataLines: [String] = []

                func noteEventYielded() -> SSEStreamError? {
                    let now = ContinuousClock.now
                    if now - rateWindowStart >= .seconds(1) {
                        rateWindowStart = now
                        rateWindowCount = 1
                        return nil
                    }
                    rateWindowCount += 1
                    if rateWindowCount > maxRate {
                        return .eventRateExceeded(rateWindowCount)
                    }
                    return nil
                }

                func flushEvent() throws -> Bool {
                    guard !dataLines.isEmpty else {
                        currentEventName = nil
                        return false
                    }
                    let payload = dataLines.joined(separator: "\n")
                    dataLines.removeAll(keepingCapacity: true)
                    defer { currentEventName = nil }

                    if payload == "[DONE]" {
                        return true
                    }

                    if let rateError = noteEventYielded() {
                        throw rateError
                    }

                    continuation.yield(NamedEvent(
                        name: currentEventName,
                        data: payload,
                        id: currentEventID
                    ))
                    return false
                }

                do {
                    while let byte = try await iterator.next() {
                        if Task.isCancelled { break }

                        totalBytes += 1
                        if totalBytes > limits.maxTotalBytes {
                            throw SSEStreamError.streamTooLarge(totalBytes)
                        }

                        if byte != UInt8(ascii: "\n") {
                            byteBuffer.append(byte)
                            if byteBuffer.count > limits.maxEventBytes {
                                throw SSEStreamError.eventTooLarge(byteBuffer.count)
                            }
                            continue
                        }

                        let line: String
                        if let decoded = String(data: byteBuffer, encoding: .utf8) {
                            line = decoded.trimmingCharacters(in: .whitespaces)
                        } else {
                            Log.network.warning("SSEStreamParser.parseNamed: skipped \(byteBuffer.count)-byte line with invalid UTF-8")
                            byteBuffer.removeAll(keepingCapacity: true)
                            continue
                        }
                        byteBuffer.removeAll(keepingCapacity: true)

                        if line.isEmpty {
                            if try flushEvent() { break }
                            continue
                        }

                        if line.hasPrefix("event:") {
                            let name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            currentEventName = name.isEmpty ? nil : name
                            continue
                        }

                        if line.hasPrefix("data:") {
                            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            dataLines.append(payload)
                            continue
                        }

                        if line.hasPrefix("id:") {
                            let id = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                            // Empty `id:` resets the last seen event ID.
                            let normalized = id.isEmpty ? nil : id
                            currentEventID = normalized
                            eventIDTracker?.update(normalized)
                            continue
                        }
                        // retry:, comments, and unknown fields are intentionally ignored.
                    }

                    // Flush terminal event if stream ended without blank separator.
                    if try flushEvent() {
                        continuation.finish()
                        return
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Streams generation events from an HTTP response using an SSE payload handler.
    ///
    /// Combines `parse(bytes:)` with a payload handler to extract tokens,
    /// emit usage reports, detect stream end, and surface errors. This
    /// eliminates the duplicated streaming loop in each cloud backend.
    ///
    /// - Parameters:
    ///   - bytes: The raw byte stream from `URLSession.bytes(for:)`.
    ///   - handler: A payload handler that interprets the provider's JSON format.
    ///   - limits: Caps that defend against hostile upstreams. Defaults to
    ///     `ManifoldConfiguration.shared.sseStreamLimits`.
    /// - Returns: An `AsyncThrowingStream` of ``GenerationEvent`` values.
    package static func streamEvents<S: AsyncSequence & Sendable>(
        from bytes: S,
        using handler: some SSEPayloadHandler,
        limits: SSEStreamLimits = ManifoldConfiguration.shared.sseStreamLimits
    ) -> AsyncThrowingStream<GenerationEvent, Error> where S.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let sseStream = parse(bytes: bytes, limits: limits)
                    var wasThinking = false
                    for try await payload in sseStream {
                        if Task.isCancelled { break }

                        for event in handler.extractEvents(from: payload) {
                            // Lifecycle: inject a single `.thinkingComplete`
                            // when the stream transitions from a thinking-
                            // token run back to a plain token. Handlers that
                            // emit `.thinkingComplete` themselves clear the
                            // flag before reaching here, so no duplicate.
                            switch event {
                            case .thinkingToken:
                                wasThinking = true
                                continuation.yield(event)
                            case .thinkingComplete:
                                wasThinking = false
                                continuation.yield(event)
                            case .token:
                                if wasThinking {
                                    continuation.yield(.thinkingComplete)
                                    wasThinking = false
                                }
                                continuation.yield(event)
                            default:
                                continuation.yield(event)
                            }
                        }

                        if let usage = handler.extractUsage(from: payload),
                           let prompt = usage.promptTokens,
                           let completion = usage.completionTokens {
                            continuation.yield(.usage(prompt: prompt, completion: completion))
                        }

                        if handler.isStreamEnd(payload) {
                            break
                        }

                        if let error = handler.extractStreamError(from: payload) {
                            throw error
                        }
                    }
                    continuation.finish()
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
