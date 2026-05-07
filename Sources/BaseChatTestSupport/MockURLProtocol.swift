import Foundation

/// A `URLProtocol` subclass that intercepts HTTP requests and returns
/// canned responses configured per-URL.
///
/// Supports three response modes:
/// - **Immediate**: returns a single `Data` blob with a status code.
/// - **SSE (chunked)**: delivers data in chunks, simulating a Server-Sent Events stream.
/// - **Error**: fails the request with a `URLError`.
///
/// ## Usage
/// ```swift
/// let config = URLSessionConfiguration.ephemeral
/// config.protocolClasses = [MockURLProtocol.self]
/// let session = URLSession(configuration: config)
///
/// MockURLProtocol.reset()
/// MockURLProtocol.stub(
///     url: someURL,
///     response: .sse(chunks: [...], statusCode: 200)
/// )
/// ```
public final class MockURLProtocol: URLProtocol {

    // MARK: - Stub Configuration

    /// Describes how a stubbed URL should respond.
    public enum StubbedResponse: @unchecked Sendable {
        /// Return data immediately with the given HTTP status code and optional extra headers.
        case immediate(data: Data, statusCode: Int, headers: [String: String] = [:])
        /// Return data in chunks (simulating SSE), with a brief delay between each.
        case sse(chunks: [Data], statusCode: Int)
        /// Return data in chunks asynchronously — each chunk is delivered on a background
        /// thread with a small delay, allowing consumers to cancel between chunks.
        case asyncSSE(chunks: [Data], chunkDelay: TimeInterval = 0.005, statusCode: Int)
        /// Return a URL error (e.g. connection lost).
        case error(Error)

        /// Return chunks asynchronously, but replace the chunk at index
        /// `corruptIndex` with `corruptedReplacement`. Exercises downstream
        /// JSON-frame parser robustness — the consumer should report a
        /// structured parse error, not crash or silently swallow the bad chunk.
        ///
        /// All other chunks are delivered verbatim.
        case corruptedJSONChunk(
            chunks: [Data],
            corruptIndex: Int,
            corruptedReplacement: Data,
            chunkDelay: TimeInterval = 0.005,
            statusCode: Int
        )

        /// Deliver every Nth chunk and skip the rest. With `every: 2`, chunks
        /// at indices 0, 2, 4 ... are delivered; chunks at 1, 3, 5 ... are
        /// dropped. Models lossy SSE delivery where the wire occasionally
        /// drops a `data:` frame.
        case droppedChunks(
            chunks: [Data],
            every: Int,
            chunkDelay: TimeInterval = 0.005,
            statusCode: Int
        )

        /// Concatenate `chunks`, deliver bytes up to `byteOffset`, then close
        /// the connection without finishing. Models a server that closes the
        /// socket mid-byte (e.g. proxy timeout). The consumer must surface a
        /// structured error rather than treat the truncated bytes as success.
        case truncatedMidByte(
            chunks: [Data],
            byteOffset: Int,
            statusCode: Int
        )

        /// Wait `firstByteDelay` (no bytes received), then deliver `data` in
        /// one shot. Models cold-start latency / queued-request head-of-line
        /// blocking. Useful for asserting `withIdleTimeout` does NOT fire
        /// before the first byte (the timer should reset on first byte).
        case delayedFirstByte(
            data: Data,
            firstByteDelay: TimeInterval,
            statusCode: Int
        )
    }

    /// Thread-safe storage for stubs keyed by absolute URL string.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [String: StubbedResponse] = [:]
    /// Ordered sequences of responses: each call pops the first element.
    /// When exhausted, falls back to the single-response stub (if any).
    private nonisolated(unsafe) static var stubSequences: [String: [StubbedResponse]] = [:]
    private nonisolated(unsafe) static var _capturedRequests: [URLRequest] = []

    /// All requests intercepted since the last `reset()` call, in order.
    public static var capturedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _capturedRequests
    }

    /// Registers a canned response for a URL.
    public static func stub(url: URL, response: StubbedResponse) {
        lock.lock()
        defer { lock.unlock() }
        stubs[url.absoluteString] = response
    }

    /// Registers an ordered sequence of responses for a URL.
    ///
    /// Each request pops the first element. When the sequence is exhausted,
    /// falls back to the single-response stub registered via ``stub(url:response:)``.
    public static func stubSequence(url: URL, responses: [StubbedResponse]) {
        lock.lock()
        defer { lock.unlock() }
        stubSequences[url.absoluteString] = responses
    }

    /// Removes the stub (and any sequence) registered for a single URL.
    ///
    /// Prefer this over ``reset()`` in test teardown — it cleans up only the
    /// current test's stub without clearing stubs registered by other suites
    /// that may be running concurrently.
    ///
    /// Also removes any captured requests for this URL so that
    /// `capturedRequests` does not accumulate stale entries across tests.
    public static func unstub(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        let key = url.absoluteString
        stubs.removeValue(forKey: key)
        stubSequences.removeValue(forKey: key)
        _capturedRequests.removeAll { $0.url?.absoluteString == key }
    }

    /// Removes all registered stubs and captured requests.
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stubs.removeAll()
        stubSequences.removeAll()
        _capturedRequests.removeAll()
    }

    /// Finds a stub matching the URL — tries sequence first, then exact match, then path-contains.
    private static func findStub(for url: URL) -> StubbedResponse? {
        lock.lock()
        defer { lock.unlock() }

        // Sequence match: pop the first element if available.
        let key = url.absoluteString
        if var seq = stubSequences[key], !seq.isEmpty {
            let next = seq.removeFirst()
            stubSequences[key] = seq
            return next
        }

        // Exact match.
        if let stub = stubs[url.absoluteString] {
            return stub
        }

        // Path-contains match: the stub URL path is contained in the request URL path.
        // Handles cases like trailing slash differences or query parameters.
        let requestPath = url.absoluteString
        for (stubURL, stub) in stubs {
            if requestPath.hasPrefix(stubURL) || stubURL.hasPrefix(requestPath) {
                return stub
            }
        }

        // No stub matched. Return nil so startLoading responds with a proper
        // URLError rather than crashing or returning the wrong suite's response.
        // The single-stub catch-all was removed because it caused cross-suite
        // contamination when two serialized suites ran concurrently: Suite A's
        // lone stub would intercept Suite B's requests and deliver the wrong
        // response, leading to hangs or assertion failures.
        return nil
    }

    // MARK: - Instance State

    private var asyncDeliveryItem: DispatchWorkItem?

    // MARK: - URLProtocol Overrides

    public override class func canInit(with request: URLRequest) -> Bool {
        // Intercept all requests when any stubs or non-exhausted sequences are registered.
        lock.lock()
        defer { lock.unlock() }
        let hasActiveSequences = stubSequences.values.contains { !$0.isEmpty }
        return !stubs.isEmpty || hasActiveSequences
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        // Capture every intercepted request for later inspection.
        Self.lock.lock()
        Self._capturedRequests.append(request)
        Self.lock.unlock()

        guard let url = request.url,
              let stub = Self.findStub(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch stub {
        case .immediate(let data, let statusCode, let extraHeaders):
            deliverResponse(statusCode: statusCode, data: data, extraHeaders: extraHeaders)

        case .sse(let chunks, let statusCode):
            deliverSSEResponse(statusCode: statusCode, chunks: chunks)

        case .asyncSSE(let chunks, let chunkDelay, let statusCode):
            deliverAsyncSSEResponse(statusCode: statusCode, chunks: chunks, chunkDelay: chunkDelay)

        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)

        case .corruptedJSONChunk(let chunks, let corruptIndex, let corruptedReplacement, let chunkDelay, let statusCode):
            var rewritten = chunks
            if rewritten.indices.contains(corruptIndex) {
                rewritten[corruptIndex] = corruptedReplacement
            }
            deliverAsyncSSEResponse(statusCode: statusCode, chunks: rewritten, chunkDelay: chunkDelay)

        case .droppedChunks(let chunks, let every, let chunkDelay, let statusCode):
            // Keep chunks at multiples of `every` (0, every, 2*every, ...).
            // Guard `every` against zero/negative — nothing kept in that case.
            let kept: [Data] = every > 0
                ? chunks.enumerated().compactMap { $0.offset.isMultiple(of: every) ? $0.element : nil }
                : []
            deliverAsyncSSEResponse(statusCode: statusCode, chunks: kept, chunkDelay: chunkDelay)

        case .truncatedMidByte(let chunks, let byteOffset, let statusCode):
            deliverTruncatedResponse(statusCode: statusCode, chunks: chunks, byteOffset: byteOffset)

        case .delayedFirstByte(let data, let firstByteDelay, let statusCode):
            deliverDelayedFirstByteResponse(statusCode: statusCode, data: data, firstByteDelay: firstByteDelay)
        }
    }

    public override func stopLoading() {
        asyncDeliveryItem?.cancel()
        asyncDeliveryItem = nil
    }

    // MARK: - Response Delivery

    private func deliverResponse(statusCode: Int, data: Data, extraHeaders: [String: String] = [:]) {
        var headers = ["Content-Type": "text/event-stream"]
        for (key, value) in extraHeaders {
            headers[key] = value
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func deliverSSEResponse(statusCode: Int, chunks: [Data]) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        for chunk in chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Delivers `chunks` concatenated up to `byteOffset` bytes total, then
    /// closes the connection without finishing. Models a server that closes
    /// the socket mid-byte (e.g. proxy timeout). The consumer must observe
    /// a transport error rather than success.
    private func deliverTruncatedResponse(statusCode: Int, chunks: [Data], byteOffset: Int) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let concatenated = chunks.reduce(Data()) { $0 + $1 }
        let cap = max(0, min(byteOffset, concatenated.count))
        if cap > 0 {
            client?.urlProtocol(self, didLoad: concatenated.prefix(cap))
        }
        // Close the connection abruptly via a URL error rather than calling
        // `urlProtocolDidFinishLoading`. This is what a real mid-byte socket
        // close looks like to URLSession's client.
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }

    /// Waits `firstByteDelay`, then delivers `data` in one shot. Useful for
    /// asserting `withIdleTimeout`-style policies do NOT fire before any
    /// bytes arrive (timer should reset on first byte).
    private func deliverDelayedFirstByteResponse(statusCode: Int, data: Data, firstByteDelay: TimeInterval) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        let client = self.client
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem {
            Thread.sleep(forTimeInterval: firstByteDelay)
            if workItem.isCancelled { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        asyncDeliveryItem = workItem
        DispatchQueue.global(qos: .default).async(execute: workItem)
    }

    /// Delivers chunks on a background thread with a small delay between each,
    /// so that async consumers have a real opportunity to cancel mid-stream.
    private func deliverAsyncSSEResponse(statusCode: Int, chunks: [Data], chunkDelay: TimeInterval) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let client = self.client
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem {
            for chunk in chunks {
                if workItem.isCancelled { break }
                Thread.sleep(forTimeInterval: chunkDelay)
                if workItem.isCancelled { break }
                client?.urlProtocol(self, didLoad: chunk)
            }
            if !workItem.isCancelled {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        asyncDeliveryItem = workItem
        DispatchQueue.global(qos: .default).async(execute: workItem)
    }
}
