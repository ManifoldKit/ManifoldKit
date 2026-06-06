import Foundation

// MARK: - SecureEnclaveKeyStoreProtocol

/// An abstraction over the Secure Enclave key storage operations used by
/// ``SecureEnclaveKeyManager``.
///
/// Conforming types provide wrap/unwrap operations for arbitrary data payloads
/// and a handle to the underlying private key. The protocol exists primarily to
/// allow test code to inject a software-backed substitute (e.g. using CryptoKit
/// AES-GCM) without requiring Keychain entitlements, while still exercising the
/// same wrap/unwrap round-trip logic that production code relies on.
public protocol SecureEnclaveKeyStoreProtocol: Sendable {

    /// Encrypts `data` using the store's wrapping key.
    ///
    /// - Throws: ``SecureEnclaveError`` on failure.
    func wrapForStorage(_ data: Data) throws -> Data

    /// Decrypts data previously produced by ``wrapForStorage(_:)``.
    ///
    /// - Throws: ``SecureEnclaveError`` on failure.
    func unwrapFromStorage(_ wrappedData: Data) throws -> Data

    /// Returns the underlying private key, generating it on first call.
    ///
    /// - Throws: ``SecureEnclaveError`` on failure.
    func getOrCreatePrivateKey() throws -> SecKey
}
