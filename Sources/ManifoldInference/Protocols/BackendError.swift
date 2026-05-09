import Foundation

/// Common protocol adopted by all backend error types so that catch sites
/// in InferenceService and the UI layer can handle errors uniformly without
/// knowing whether the failure came from a local or cloud backend.
///
/// The `isRetryable` property lets call sites decide whether to surface a
/// transient error with a retry prompt or treat it as permanent.
public protocol BackendError: LocalizedError, Sendable {
    /// Whether the error is transient and the operation may be retried
    /// without any configuration change.
    var isRetryable: Bool { get }
}

extension InferenceError: BackendError {}
extension CloudBackendError: BackendError {}
