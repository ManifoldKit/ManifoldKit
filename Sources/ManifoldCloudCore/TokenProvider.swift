import Foundation

/// Supplies bearer tokens to a cloud backend on each request.
///
/// Implement this protocol to provide rotating credentials — OAuth access
/// tokens, JWTs, or any credential that may expire and need async refresh.
/// The backend calls ``token()`` on every outbound request, so the
/// implementation can refresh silently without the caller noticing.
///
/// For static API keys prefer the existing
/// ``SSECloudBackend/configure(baseURL:keychainAccount:modelName:)`` overload,
/// which reads from Keychain without the overhead of an async hop.
public protocol TokenProvider: Sendable {
    /// Returns a valid bearer token. May perform a network round-trip to
    /// refresh an expired token before returning.
    func token() async throws -> String
}
