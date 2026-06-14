import Foundation
// KeychainService (ManifoldSecrets) and CloudBackendError (ManifoldModelCatalog)
// resolve through ManifoldInference's @_exported import chain — matching how
// SSECloudBackend reaches KeychainService with only this import.
import ManifoldInference

/// A ``TokenProvider`` that reads its credential from the Keychain on every
/// ``token()`` call.
///
/// Unlike ``SSECloudBackend/configure(baseURL:keychainAccount:modelName:)``,
/// which also resolves from Keychain, this provider exists to satisfy the
/// ``TokenProvider`` abstraction so a single configuration path
/// (``SSECloudBackend/configure(baseURL:tokenProvider:modelName:)``) can serve
/// both rotating OAuth/JWT credentials *and* static Keychain-backed API keys.
///
/// The read happens on **each** ``token()`` call rather than being cached at
/// init, so rotating the stored credential (overwriting the Keychain item)
/// takes effect immediately — no backend rebuild or reconfigure needed.
///
/// ### Injection for tests
///
/// `KeychainService` is a static-only enum, so it cannot be passed as an
/// instance. The retrieval is therefore injected as a closure (defaulting to
/// ``KeychainService/retrieve(account:)``). Tests pass an in-memory closure to
/// exercise the read-each-call behavior without touching the real Keychain.
public struct KeychainTokenProvider: TokenProvider {

    /// The Keychain account identifier whose stored secret is the bearer token.
    public let keychainAccount: String

    /// Resolves the current secret for an account. Defaults to the real
    /// ``KeychainService``; tests inject an in-memory closure.
    private let retrieve: @Sendable (String) -> String?

    /// Creates a provider that reads `keychainAccount` from the Keychain on
    /// every ``token()`` call.
    ///
    /// - Parameters:
    ///   - keychainAccount: the Keychain account holding the credential.
    ///   - retrieve: the lookup closure. Defaults to
    ///     ``KeychainService/retrieve(account:)`` — production code should rely
    ///     on the default so reads always hit the live Keychain.
    public init(
        keychainAccount: String,
        retrieve: @escaping @Sendable (String) -> String? = { KeychainService.retrieve(account: $0) }
    ) {
        self.keychainAccount = keychainAccount
        self.retrieve = retrieve
    }

    /// Returns the credential currently stored for ``keychainAccount``.
    ///
    /// Re-reads on every call so credential rotation is picked up without a
    /// reconfigure. Throws ``CloudBackendError/authenticationFailed(provider:)``
    /// when no credential is present rather than returning an empty token that
    /// would surface later as an opaque upstream 401.
    public func token() async throws -> String {
        guard let value = retrieve(keychainAccount), !value.isEmpty else {
            throw CloudBackendError.authenticationFailed(provider: "KeychainTokenProvider(\(keychainAccount))")
        }
        return value
    }
}
