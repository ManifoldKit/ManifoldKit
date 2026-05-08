import Foundation

/// Fans out `URLSession` delegate callbacks to multiple cooperating delegates.
///
/// `URLSession` accepts only a single `delegate:` reference at session-creation
/// time, but the security model needs both certificate pinning (handled by
/// ``PinnedSessionDelegate`` in BaseChatBackends) **and** redirect interception
/// (handled by ``RedirectGuardDelegate``) on the same session. This composite
/// owns both delegates and forwards each callback to whichever child cares
/// about it.
///
/// ## Forwarding rules
///
/// - `urlSession(_:didReceive:completionHandler:)` (server-trust challenge)
///   is forwarded to ``serverTrustHandler`` if non-nil; otherwise the default
///   handling fires. Only one delegate may handle a given challenge — a
///   second call to `completionHandler` is a programming error in URLSession.
/// - `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`
///   is forwarded to ``redirectGuard`` (always present).
/// - Download / data delegate callbacks (`didFinishDownloadingTo`,
///   `didWriteData`, `didReceive data:`, `didCompleteWithError`, etc.) are
///   forwarded to ``downloadDelegate`` when present, so a `BackgroundDownloadManager`
///   can plug in without losing redirect-guard coverage.
///
/// ## Sendability
///
/// `@unchecked Sendable` is justified here because:
/// - `redirectGuard` and `serverTrustHandler` are `let` after init.
/// - `downloadDelegate` is a weak reference set once at init.
/// - Each child delegate handles its own internal synchronisation
///   (`RedirectGuardDelegate` uses `NSLock`; `PinnedSessionDelegate` uses
///   class-level `NSLock` for its pin sets).
public final class CompositeURLSessionDelegate: NSObject, @unchecked Sendable {

    /// Always-present redirect interceptor.
    public let redirectGuard: RedirectGuardDelegate

    /// Optional server-trust handler. When non-nil, receives every
    /// `NSURLAuthenticationMethodServerTrust` challenge. Typically a
    /// `PinnedSessionDelegate` instance.
    public let serverTrustHandler: URLSessionDelegate?

    /// Optional download / data delegate. Used by `BackgroundDownloadManager`
    /// to receive `didFinishDownloadingTo` etc. while still benefiting from
    /// the redirect guard.
    ///
    /// Held as a `weak` reference so callers (typically `@MainActor`-owned
    /// download managers) can be released without keeping the URLSession
    /// alive past their lifetime.
    public weak var downloadDelegate: URLSessionDownloadDelegate?

    /// Optional generic data-task delegate. Same plug shape as
    /// ``downloadDelegate`` but for non-download data tasks.
    public weak var dataDelegate: URLSessionDataDelegate?

    public init(
        redirectGuard: RedirectGuardDelegate,
        serverTrustHandler: URLSessionDelegate? = nil,
        downloadDelegate: URLSessionDownloadDelegate? = nil,
        dataDelegate: URLSessionDataDelegate? = nil
    ) {
        self.redirectGuard = redirectGuard
        self.serverTrustHandler = serverTrustHandler
        self.downloadDelegate = downloadDelegate
        self.dataDelegate = dataDelegate
    }
}

// MARK: - URLSessionDelegate

extension CompositeURLSessionDelegate: URLSessionDelegate {

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // The pinning delegate (when present) owns the response — its
        // `urlSession(_:didReceive:completionHandler:)` is required to call
        // `completionHandler` exactly once. The method is `@objc optional`
        // on `URLSessionDelegate`, so we use `responds(to:)` to gate the
        // forward — without the gate, an unimplemented selector silently
        // drops the call and hangs the request.
        let selector = #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))
        if let handler = serverTrustHandler, handler.responds(to: selector) {
            handler.urlSession?(session, didReceive: challenge, completionHandler: completionHandler)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    public func urlSession(
        _ session: URLSession,
        didBecomeInvalidWithError error: Error?
    ) {
        // Forward to download delegate so BackgroundDownloadManager can
        // observe session invalidation (e.g. during teardown).
        downloadDelegate?.urlSession?(session, didBecomeInvalidWithError: error)
        dataDelegate?.urlSession?(session, didBecomeInvalidWithError: error)
    }

    #if os(iOS)
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        downloadDelegate?.urlSessionDidFinishEvents?(forBackgroundURLSession: session)
    }
    #endif
}

// MARK: - URLSessionTaskDelegate

extension CompositeURLSessionDelegate: URLSessionTaskDelegate {

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Redirect guard always handles redirects — it owns the policy
        // (hop cap, IP filter, scheme-downgrade reject, header strip).
        redirectGuard.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler
        )
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Tell the redirect guard to free its per-task hop counter.
        redirectGuard.urlSession(session, task: task, didCompleteWithError: error)
        // Forward to download/data delegates so they can observe completion.
        downloadDelegate?.urlSession?(session, task: task, didCompleteWithError: error)
        dataDelegate?.urlSession?(session, task: task, didCompleteWithError: error)
    }
}

// MARK: - URLSessionDownloadDelegate

extension CompositeURLSessionDelegate: URLSessionDownloadDelegate {

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        downloadDelegate?.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        downloadDelegate?.urlSession?(
            session,
            downloadTask: downloadTask,
            didWriteData: bytesWritten,
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        downloadDelegate?.urlSession?(
            session,
            downloadTask: downloadTask,
            didResumeAtOffset: fileOffset,
            expectedTotalBytes: expectedTotalBytes
        )
    }
}

// MARK: - URLSessionDataDelegate

extension CompositeURLSessionDelegate: URLSessionDataDelegate {

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        dataDelegate?.urlSession?(session, dataTask: dataTask, didReceive: data)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let dataDelegate {
            dataDelegate.urlSession?(
                session,
                dataTask: dataTask,
                didReceive: response,
                completionHandler: completionHandler
            )
        } else {
            completionHandler(.allow)
        }
    }
}
