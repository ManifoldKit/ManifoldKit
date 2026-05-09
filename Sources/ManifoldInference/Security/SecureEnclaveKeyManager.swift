import Foundation
import Security

// MARK: - SecureEnclaveError

/// Errors thrown by ``SecureEnclaveKeyManager``.
public enum SecureEnclaveError: Error, Equatable, Sendable, LocalizedError {
    /// The Secure Enclave is not available on this device or environment
    /// (e.g. iOS Simulator, Intel Mac without T2 chip).
    case notAvailable
    /// Key generation via `SecKeyCreateRandomKey` failed.
    case keyGenerationFailed(String)
    /// A wrap or unwrap operation via `SecKeyCreateEncryptedData` /
    /// `SecKeyCreateDecryptedData` failed.
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Secure Enclave is not available on this device."
        case .keyGenerationFailed(let msg):
            return "Secure Enclave key generation failed: \(msg)"
        case .operationFailed(let msg):
            return "Secure Enclave operation failed: \(msg)"
        }
    }
}

// MARK: - SecureEnclaveKeyManager

/// Manages a per-app hardware-backed wrapping key resident in the Secure Enclave.
///
/// On capable hardware (Apple Silicon, T2 Mac, and devices with a dedicated
/// SE chiplet), an Elliptic Curve P-256 private key is generated and stored
/// permanently inside the Secure Enclave. The private key material **never**
/// leaves the SE; all cryptographic operations occur inside the chiplet.
///
/// Wrap and unwrap operations use ECIES with the
/// `eciesEncryptionCofactorVariableIVX963SHA256AESGCM` algorithm — an
/// authenticated-encryption construction that provides both confidentiality
/// and integrity on the wrapped payload.
///
/// On simulators and older hardware where the Secure Enclave is unavailable,
/// all operations throw ``SecureEnclaveError/notAvailable``. Gate usage with
/// ``ManifoldConfiguration/useSecureEnclave`` and check
/// ``SecureEnclaveKeyManager/isAvailable`` at runtime before calling
/// wrap/unwrap operations.
///
/// The shared singleton caches the `SecKey` reference in memory after the
/// first successful lookup to avoid repeated Keychain round-trips.
///
/// ## Round-trip example
///
/// ```swift
/// let manager = SecureEnclaveKeyManager.shared
/// let payload = Data("sk-secret".utf8)
/// let wrapped = try manager.wrapForStorage(payload)
/// let recovered = try manager.unwrapFromStorage(wrapped)
/// // recovered == payload
/// ```
public final class SecureEnclaveKeyManager: @unchecked Sendable {

    /// The process-wide singleton. Operations are thread-safe via an internal lock.
    public static let shared = SecureEnclaveKeyManager()

    // Keychain application tag for the SE wrapping keypair.
    // Using a stable tag lets the key survive across app updates.
    private static let keyTagData = Data("com.manifoldkit.sekey.v1".utf8)

    private let lock = NSLock()
    private var _cachedPrivateKey: SecKey?

    private init() {}

    // MARK: - Availability

    /// Whether the Secure Enclave is accessible on the current device and runtime.
    ///
    /// Returns `false` in the iOS/macOS Simulator and on Intel Macs without a
    /// T2 chip. Check this before calling any wrap/unwrap operation if you want
    /// to branch on availability rather than catching the thrown error.
    public static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        var error: Unmanaged<CFError>?
        let control = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &error
        )
        return control != nil && error == nil
        #endif
    }

    // MARK: - Key Lifecycle

    /// Returns the SE-resident private key, generating it on first call.
    ///
    /// The key is stored permanently in the Keychain (`kSecAttrIsPermanent: true`)
    /// with access class `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Subsequent
    /// calls return the same `SecKey` reference from the Keychain (or the in-process
    /// cache) without generating a new key.
    ///
    /// - Throws: ``SecureEnclaveError/notAvailable`` if the SE is unavailable;
    ///   ``SecureEnclaveError/keyGenerationFailed(_:)`` on any generation error.
    public func getOrCreatePrivateKey() throws -> SecKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached = _cachedPrivateKey { return cached }
        let key = try resolveOrGenerateLocked()
        _cachedPrivateKey = key
        return key
    }

    /// Removes the cached `SecKey` reference from memory.
    ///
    /// The key itself remains in the Keychain. Call this during low-memory
    /// conditions or security-sensitive teardown; the next wrap/unwrap call
    /// will reload the key from the Keychain.
    public func evictCachedKey() {
        lock.lock()
        defer { lock.unlock() }
        _cachedPrivateKey = nil
    }

    // MARK: - Wrap / Unwrap

    /// Encrypts `data` using the SE-resident public key (ECIES).
    ///
    /// The resulting ciphertext is bound to this device's Secure Enclave and
    /// can only be decrypted by ``unwrapFromStorage(_:)`` on the same device.
    /// Safe to persist in the Keychain, SQLite, or any at-rest store alongside
    /// its metadata.
    ///
    /// - Throws: ``SecureEnclaveError/notAvailable`` if the SE is unavailable;
    ///   ``SecureEnclaveError/operationFailed(_:)`` if encryption fails.
    public func wrapForStorage(_ data: Data) throws -> Data {
        guard Self.isAvailable else { throw SecureEnclaveError.notAvailable }
        let privateKey = try getOrCreatePrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecureEnclaveError.keyGenerationFailed("Could not derive public key from SE private key")
        }
        let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            throw SecureEnclaveError.operationFailed("ECIES algorithm not supported on this key")
        }
        var encryptError: Unmanaged<CFError>?
        guard let ciphertext = SecKeyCreateEncryptedData(
            publicKey, algorithm, data as CFData, &encryptError
        ) as Data? else {
            let msg = encryptError.map { ($0.takeRetainedValue() as Error).localizedDescription }
                ?? "Encryption returned nil"
            throw SecureEnclaveError.operationFailed("Wrap failed: \(msg)")
        }
        return ciphertext
    }

    /// Decrypts data previously wrapped by ``wrapForStorage(_:)`` using the
    /// SE-resident private key (ECIES).
    ///
    /// - Throws: ``SecureEnclaveError/notAvailable`` if the SE is unavailable;
    ///   ``SecureEnclaveError/operationFailed(_:)`` if decryption fails (e.g.
    ///   tampered ciphertext or key mismatch).
    public func unwrapFromStorage(_ wrappedData: Data) throws -> Data {
        guard Self.isAvailable else { throw SecureEnclaveError.notAvailable }
        let privateKey = try getOrCreatePrivateKey()
        let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else {
            throw SecureEnclaveError.operationFailed("ECIES algorithm not supported on this key")
        }
        var decryptError: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(
            privateKey, algorithm, wrappedData as CFData, &decryptError
        ) as Data? else {
            let msg = decryptError.map { ($0.takeRetainedValue() as Error).localizedDescription }
                ?? "Decryption returned nil"
            throw SecureEnclaveError.operationFailed("Unwrap failed: \(msg)")
        }
        return plaintext
    }

    // MARK: - Private

    private func resolveOrGenerateLocked() throws -> SecKey {
        guard Self.isAvailable else { throw SecureEnclaveError.notAvailable }

        // Try to load an existing SE key from the Keychain.
        let findQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.keyTagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
        ]
        var keyRef: AnyObject?
        let findStatus = SecItemCopyMatching(findQuery as CFDictionary, &keyRef)
        if findStatus == errSecSuccess, let existing = keyRef {
            return existing as! SecKey // swiftlint:disable:this force_cast
        }
        if Self.isUnavailableKeychainStatus(findStatus) {
            throw SecureEnclaveError.notAvailable
        }

        // Generate a new SE-resident P-256 private key.
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &accessError
        ) else {
            let msg = accessError.map { ($0.takeRetainedValue() as Error).localizedDescription }
                ?? "SecAccessControlCreateWithFlags returned nil"
            throw SecureEnclaveError.keyGenerationFailed(msg)
        }

        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrApplicationTag as String: Self.keyTagData,
                kSecAttrAccessControl as String: access,
                kSecAttrIsPermanent as String: true,
            ] as [String: Any],
        ]

        var keyGenError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &keyGenError) else {
            let cfErr = keyGenError?.takeRetainedValue()
            if let code = cfErr.map({ OSStatus(CFErrorGetCode($0)) }),
               Self.isUnavailableKeychainStatus(code) {
                throw SecureEnclaveError.notAvailable
            }
            let msg = cfErr.map { ($0 as Error).localizedDescription }
                ?? "SecKeyCreateRandomKey returned nil"
            throw SecureEnclaveError.keyGenerationFailed(msg)
        }

        // Attempt to persist the generated key.  If the process lacks the
        // necessary Keychain entitlements (-34018), treat the SE as unavailable
        // rather than propagating a confusing error.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.keyTagData,
            kSecValueRef as String: privateKey,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if Self.isUnavailableKeychainStatus(addStatus) {
            throw SecureEnclaveError.notAvailable
        }
        // errSecDuplicateItem is fine — another thread beat us; load the
        // key that's already there.
        if addStatus == errSecDuplicateItem {
            var ref: AnyObject?
            let reloadStatus = SecItemCopyMatching(findQuery as CFDictionary, &ref)
            if reloadStatus == errSecSuccess, let reloaded = ref {
                return reloaded as! SecKey // swiftlint:disable:this force_cast
            }
        }

        return privateKey
    }

    private static func isUnavailableKeychainStatus(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecInteractionNotAllowed
    }
}
