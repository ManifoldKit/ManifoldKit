import CryptoKit
import Foundation
import ManifoldInference
import Security

// MARK: - MockSecureEnclaveKeyStore

/// A software-backed substitute for ``SecureEnclaveKeyManager`` that uses
/// CryptoKit AES-GCM for wrap/unwrap operations.
///
/// This mock exists so ``SecureEnclaveKeyManagerTests`` can exercise the full
/// wrap/unwrap round-trip on machines where `swift test` ad-hoc signed binaries
/// lack Keychain entitlements (and therefore cannot create SE-backed keys).
/// Real authenticated encryption is used, so the crypto correctness of the
/// round-trip is still verified — only the hardware key storage is stubbed out.
///
/// `getOrCreatePrivateKey()` is intentionally unsupported: the mock is designed
/// for tests that verify wrap/unwrap behaviour. Tests that specifically exercise
/// the raw `SecKey` API should run only on hardware with proper entitlements
/// (and gate themselves with `XCTSkipIf`).
public final class MockSecureEnclaveKeyStore: SecureEnclaveKeyStoreProtocol {

    private let key: SymmetricKey

    /// Creates a new instance with a freshly generated 256-bit AES key.
    public init() {
        key = SymmetricKey(size: .bits256)
    }

    // MARK: - SecureEnclaveKeyStoreProtocol

    public func wrapForStorage(_ data: Data) throws -> Data {
        do {
            let sealed = try AES.GCM.seal(data, using: key)
            guard let combined = sealed.combined else {
                throw SecureEnclaveError.operationFailed("AES-GCM seal produced no combined data")
            }
            return combined
        } catch let error as SecureEnclaveError {
            throw error
        } catch {
            throw SecureEnclaveError.operationFailed("AES-GCM seal failed: \(error.localizedDescription)")
        }
    }

    public func unwrapFromStorage(_ wrappedData: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: wrappedData)
            return try AES.GCM.open(box, using: key)
        } catch let error as SecureEnclaveError {
            throw error
        } catch {
            throw SecureEnclaveError.operationFailed("AES-GCM open failed: \(error.localizedDescription)")
        }
    }

    /// Not supported on this mock — use ``SecureEnclaveKeyManager/shared`` on
    /// hardware with Keychain entitlements if you need a real `SecKey`.
    public func getOrCreatePrivateKey() throws -> SecKey {
        throw SecureEnclaveError.operationFailed(
            "MockSecureEnclaveKeyStore does not vend SecKey — " +
            "inject SecureEnclaveKeyManager.shared on entitled hardware instead"
        )
    }
}
