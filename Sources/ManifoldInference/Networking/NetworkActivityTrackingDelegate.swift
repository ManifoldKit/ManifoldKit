import Foundation

/// `URLSessionDataDelegate` that reports request lifecycle to
/// ``NetworkActivityCenter``.
///
/// Wired into the data-delegate slot of ``CompositeURLSessionDelegate`` by
/// ``URLSessionFactory/ephemeral(hopCap:resourceTimeout:additionalDataDelegate:activityCenter:)``.
/// Begin events fire when the server delivers either the first headers
/// (`didReceive response:`) or the first body byte (`didReceive data:`),
/// whichever arrives first — both are guaranteed to precede
/// `didCompleteWithError`, which fires end.
///
/// ## Why first response, not task creation
///
/// `URLSession` exposes no "task is about to start" delegate callback. Hooking
/// from the caller (right before `task.resume()`) would catch creation but
/// duplicate the responsibility across every call site. Reporting on first
/// response keeps the funnel inside the session delegate where the redirect
/// guard already lives, so any future production caller is covered for free.
///
/// ## Forwarding
///
/// All callbacks are forwarded to ``downstream`` so the caller-supplied
/// data delegate (e.g. an SSE consumer) still sees them. This delegate is
/// purely additive.
final class NetworkActivityTrackingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// Center to notify. Defaults to ``NetworkActivityCenter/shared``.
    private let center: NetworkActivityCenter

    /// Optional caller-supplied data delegate. Forwarded after the tracking
    /// hook fires.
    weak var downstream: URLSessionDataDelegate?

    /// Maps `URLSessionTask.taskIdentifier` to the activity token issued for
    /// that task. Reads/writes are serialised on ``lock`` — URLSession may
    /// deliver delegate callbacks on its own queue, off the main actor.
    private let lock = NSLock()
    private var tokens: [Int: NetworkActivityToken] = [:]

    init(center: NetworkActivityCenter, downstream: URLSessionDataDelegate? = nil) {
        self.center = center
        self.downstream = downstream
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        ensureBegin(for: dataTask)
        if let downstream {
            downstream.urlSession?(
                session,
                dataTask: dataTask,
                didReceive: response,
                completionHandler: completionHandler
            )
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        ensureBegin(for: dataTask)
        downstream?.urlSession?(session, dataTask: dataTask, didReceive: data)
    }

    // MARK: - URLSessionTaskDelegate (forwarded via Composite)

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        endIfActive(for: task)
        downstream?.urlSession?(session, task: task, didCompleteWithError: error)
    }

    // MARK: - Helpers

    private func ensureBegin(for task: URLSessionTask) {
        lock.lock()
        if tokens[task.taskIdentifier] != nil {
            lock.unlock()
            return
        }
        let host = task.originalRequest?.url?.host ?? ""
        // Place a sentinel in the map *before* hopping to the main actor so a
        // late callback on the same task cannot double-begin while the hop is
        // queued. The real token replaces the sentinel below.
        let placeholder = NetworkActivityToken()
        tokens[task.taskIdentifier] = placeholder
        lock.unlock()
        let center = self.center
        Task { @MainActor in
            // `.generic` keeps the call site honest: the tracking delegate
            // doesn't know whether a given task is a probe, a manifest fetch,
            // or generic SSE traffic. Callers that need precise kinds invoke
            // `NetworkActivityCenter.begin(kind:host:)` directly.
            let realToken = center.begin(kind: .generic, host: host)
            self.replaceToken(at: task.taskIdentifier, with: realToken, placeholder: placeholder)
        }
    }

    private func replaceToken(
        at taskID: Int,
        with token: NetworkActivityToken,
        placeholder: NetworkActivityToken
    ) {
        lock.lock()
        // Only swap when the placeholder is still in place. If endIfActive
        // already removed the slot the request finished before our hop landed
        // — close the just-issued token immediately so the center doesn't
        // leak a phantom in-flight entry.
        if tokens[taskID] == placeholder {
            tokens[taskID] = token
            lock.unlock()
        } else {
            lock.unlock()
            Task { @MainActor in
                self.center.end(token)
            }
        }
    }

    private func endIfActive(for task: URLSessionTask) {
        lock.lock()
        let token = tokens.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let token else { return }
        let center = self.center
        Task { @MainActor in
            center.end(token)
        }
    }
}
