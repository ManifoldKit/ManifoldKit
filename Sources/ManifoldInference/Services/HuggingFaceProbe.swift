import Foundation

/// Implementation backing ``HuggingFaceServiceProtocol/probe(timeout:)``.
///
/// Split out from the protocol extension so the same logic can be exercised
/// from tests against an injected `URLSession` wired to `MockURLProtocol`,
/// rather than reaching live `huggingface.co` during CI.
///
/// The well-known probe endpoint is `https://huggingface.co/api/models?limit=1`.
/// `HEAD` was attempted first but `huggingface.co` returns `405 Method Not
/// Allowed` on `/api/models`, so a `GET` is used instead — the JSON body is
/// drained into memory but discarded. `limit=1` keeps the response under a
/// few hundred bytes.
package enum HuggingFaceProbe {

    /// Default probe URL. Public so tests in this module can construct
    /// requests against the same endpoint used in production.
    package static let defaultURL = URL(string: "https://huggingface.co/api/models?limit=1")!

    /// Runs the probe against ``defaultURL`` using a redirect-guarded
    /// ephemeral session from ``URLSessionFactory``.
    ///
    /// Never throws — failures are reported via
    /// ``ProbeResult/failureReason``.
    package static func run(timeout: TimeInterval) async -> ProbeResult {
        // Cap the underlying URL request as well as the outer wall-clock
        // budget. `timeoutIntervalForRequest` bounds idle time between bytes;
        // we still want the wall-clock cap to dominate on a wedged TLS
        // handshake, hence the manual `withTimeout` below.
        let session = URLSessionFactory.ephemeral(resourceTimeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        return await run(url: defaultURL, timeout: timeout, session: session)
    }

    /// Test seam: same probe logic, but against a caller-supplied URL and
    /// `URLSession`. Tests register a `MockURLProtocol` stub and pass the
    /// resulting session.
    static func run(url: URL, timeout: TimeInterval, session: URLSession) async -> ProbeResult {
        let clock = ContinuousClock()
        let start = clock.now

        // Build the request as a `let` so its capture by the @Sendable
        // closure below cannot trip strict-concurrency `captured var` errors.
        let request: URLRequest = {
            var r = URLRequest(url: url)
            r.httpMethod = "GET"
            r.timeoutInterval = timeout
            // No Authorization header — anonymous reachability probe.
            return r
        }()

        let outcome = await withTimeout(timeout: timeout) { () -> ProbeOutcome in
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    return .response(status: http.statusCode)
                }
                return .transportFailure(reason: "Unexpected response type")
            } catch let urlError as URLError {
                return .transportFailure(reason: Self.sanitise(urlError: urlError))
            } catch {
                return .transportFailure(reason: "Network error")
            }
        }

        let latency = clock.now - start
        let timestamp = Date()

        switch outcome {
        case .timeout:
            Log.network.warning("HuggingFace probe timed out after \(timeout)s")
            return ProbeResult(
                succeeded: false,
                httpStatus: nil,
                latency: latency,
                timestamp: timestamp,
                failureReason: "Request timed out"
            )
        case .transportFailure(let reason):
            Log.network.warning("HuggingFace probe transport failure: \(reason, privacy: .public)")
            return ProbeResult(
                succeeded: false,
                httpStatus: nil,
                latency: latency,
                timestamp: timestamp,
                failureReason: reason
            )
        case .response(let status):
            let ok = (200..<300).contains(status)
            return ProbeResult(
                succeeded: ok,
                httpStatus: status,
                latency: latency,
                timestamp: timestamp,
                failureReason: ok ? nil : "HTTP \(status)"
            )
        }
    }

    private enum ProbeOutcome: Sendable {
        case response(status: Int)
        case transportFailure(reason: String)
        case timeout
    }

    /// Wall-clock cap. `URLSession`'s own `timeoutIntervalForRequest` only
    /// bounds the inter-byte idle window; this races the request against a
    /// `Task.sleep` so a wedged TLS handshake or a misbehaving proxy cannot
    /// outlive the caller's budget.
    private static func withTimeout(
        timeout: TimeInterval,
        operation: @Sendable @escaping () async -> ProbeOutcome
    ) async -> ProbeOutcome {
        await withTaskGroup(of: ProbeOutcome.self) { group in
            group.addTask { await operation() }
            group.addTask {
                let nanos = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
    }

    /// Reduces a `URLError` to a short, PII-free reason string. Mirrors the
    /// intent of `CloudErrorSanitizer` in `ManifoldCloudCore` (which is
    /// trait-gated and not reachable from `ManifoldInference`): never echo
    /// raw URLs, hostnames, tokens, HTML, or stack traces — bucket the error
    /// by code and emit a short, stable label.
    ///
    /// Kept distinct from ``ManifoldKitError/errorDescription`` because this
    /// returns a compact log label ("DNS lookup failed") whereas the rim's
    /// strings are user-facing sentences. See ``ManifoldKitError/from(_:)``
    /// for the consumer-presentable mapping.
    static func sanitise(urlError: URLError) -> String {
        switch urlError.code {
        case .timedOut:
            return "Request timed out"
        case .cannotFindHost, .dnsLookupFailed:
            return "DNS lookup failed"
        case .cannotConnectToHost, .networkConnectionLost:
            return "Cannot connect to host"
        case .notConnectedToInternet:
            return "Not connected to the internet"
        case .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return "TLS handshake failed"
        case .cancelled:
            return "Request cancelled"
        case .badServerResponse, .zeroByteResource, .cannotParseResponse:
            return "Malformed server response"
        case .httpTooManyRedirects, .redirectToNonExistentLocation:
            return "Too many redirects"
        case .unsupportedURL, .badURL:
            return "Invalid probe URL"
        default:
            return "Network error"
        }
    }
}
