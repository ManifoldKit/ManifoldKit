import Foundation
import ManifoldInference

internal final class BackgroundURLSessionCoordinator: @unchecked Sendable {
    private let sessionIdentifier: String
    private weak var downloadDelegate: (NSObject & URLSessionDownloadDelegate)?
    private var backgroundSession: URLSession?

    internal init(
        sessionIdentifier: String,
        downloadDelegate: NSObject & URLSessionDownloadDelegate
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.downloadDelegate = downloadDelegate
    }

    internal func downloadTask(with url: URL) -> URLSessionDownloadTask {
        session.downloadTask(with: url)
    }

    internal func downloadTask(withResumeData resumeData: Data) -> URLSessionDownloadTask {
        session.downloadTask(withResumeData: resumeData)
    }

    internal func getAllTasks(completionHandler: @escaping @Sendable ([URLSessionTask]) -> Void) {
        session.getAllTasks(completionHandler: completionHandler)
    }

    internal func reconnect() {
        _ = session
    }

    internal func invalidateAndCancel() {
        backgroundSession?.invalidateAndCancel()
    }

    private var session: URLSession {
        if let existing = backgroundSession { return existing }
        guard let downloadDelegate else {
            preconditionFailure("BackgroundURLSessionCoordinator used after delegate deallocation")
        }
        let session = URLSessionFactory.background(
            identifier: sessionIdentifier,
            additionalDownloadDelegate: downloadDelegate
        )
        backgroundSession = session
        return session
    }
}
