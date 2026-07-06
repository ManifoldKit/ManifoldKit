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

// `ManifoldKitError` is defined in `ManifoldModelCatalog`, which
// `ManifoldContract` already `@_exported import`s (see
// `ManifoldContractLeafExports.swift`) — declaring the conformance here
// mirrors the `CloudBackendError` precedent above rather than adding a new
// cross-module edge. See docs/error-boundary escapable-types table (DocC:
// ManifoldRuntime "Error handling at the boundary") for why this is one of
// the ~escapable set: it is the terminal wrap-everything rim thrown by
// `ManifoldKit.quickStart(configuration:)`.
extension ManifoldKitError: BackendError {}
