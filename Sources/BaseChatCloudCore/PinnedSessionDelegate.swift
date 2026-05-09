#if CloudSaaS
import Foundation
import CommonCrypto
import BaseChatInference

/// URLSession delegate that performs certificate pinning for known API hosts.
///
/// Validates the server's leaf certificate SPKI (Subject Public Key Info) SHA-256
/// hash against a set of known pins for Anthropic and OpenAI APIs. Connections to
/// unknown hosts (custom endpoints) are governed by
/// ``BaseChatConfiguration/customHostTrustPolicy``: the default
/// (``.platformDefault``) falls through to OS trust evaluation; ``.requireExplicitPins``
/// rejects any host without configured pins (fail-closed).
/// Localhost hosts always bypass pinning.
///
/// Pin rotation: when a provider rotates certificates, update the pin sets below.
/// Include at least one backup pin per host to avoid lockout during rotation.
public final class PinnedSessionDelegate: NSObject, URLSessionDelegate {

    // MARK: - Pin Sets

    // NSLock guards concurrent reads/writes from multiple URLSession delegate
    // callback threads, which can arrive on arbitrary background threads.
    private static let _pinnedHostsLock = NSLock()
    private nonisolated(unsafe) static var _pinnedHosts: [String: Set<String>] = [:]

    /// SPKI SHA-256 hashes for known API hosts.
    ///
    /// To generate a pin from a certificate:
    /// ```bash
    /// openssl s_client -connect api.anthropic.com:443 </dev/null 2>/dev/null | \
    ///   openssl x509 -pubkey -noout | \
    ///   openssl pkey -pubin -outform DER | \
    ///   openssl dgst -sha256 -binary | base64
    /// ```
    ///
    /// Default pins are populated lazily by `loadDefaultPins()` on first access.
    /// Today that function ships two SPKI hashes — the Google Trust Services WE1
    /// intermediate CA and its issuing GTS Root R4 — and applies them to both
    /// `api.openai.com` and `api.anthropic.com` because both providers sit
    /// behind Google Trust Services. Pinning the intermediate (plus the root as
    /// a backup) rather than the leaf keeps the pin set stable across routine
    /// leaf-certificate renewals: pins only need to change when a provider
    /// rotates its signing infrastructure.
    ///
    /// `api.openai.com` and `api.anthropic.com` are treated as required pinned
    /// production hosts: missing or empty pin sets fail closed.
    /// Unknown custom hosts continue to use default trust when no pins are set.
    ///
    /// Host apps that need to override or extend the shipped pin set (e.g.
    /// pointing a provider at a private gateway with its own CA) can write
    /// directly to `pinnedHosts` before any network requests are issued; values
    /// set by the host app are preserved by `loadDefaultPins()`.
    public static var pinnedHosts: [String: Set<String>] {
        get {
            _pinnedHostsLock.lock()
            defer { _pinnedHostsLock.unlock() }
            return _pinnedHosts
        }
        set {
            _pinnedHostsLock.lock()
            defer { _pinnedHostsLock.unlock() }
            _pinnedHosts = newValue
        }
    }

    // One-shot guard so `loadDefaultPins()` is idempotent across callers.
    private nonisolated(unsafe) static var _defaultPinsLoaded = false

    /// Populates pin sets for known production hosts on first access.
    ///
    /// Pins target the intermediate CA (Google Trust Services WE1) and its
    /// issuing root (GTS Root R4). Intermediate pins are more stable than leaf
    /// pins — they survive individual certificate renewals and only change when
    /// the provider rotates its signing infrastructure.
    ///
    /// **Rotation procedure:**
    /// 1. Run the `openssl` pipeline from the doc comment above for each host.
    /// 2. Add the *new* intermediate/root pins to the set **before** removing old ones.
    /// 3. Ship the update. Once no connections use the old chain, remove stale pins.
    public static func loadDefaultPins() {
        _pinnedHostsLock.lock()
        defer { _pinnedHostsLock.unlock() }
        guard !_defaultPinsLoaded else { return }
        _defaultPinsLoaded = true

        // Google Trust Services WE1 (intermediate — shared by both hosts)
        let gtsWE1 = "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4="
        // GTS Root R4 (root CA — backup pin for rotation safety)
        let gtsRootR4 = "mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c="
        let defaults = Set([gtsWE1, gtsRootR4])

        // Only set defaults if the host app hasn't already configured pins.
        // Access _pinnedHosts directly — we already hold the lock.
        for host in ["api.anthropic.com", "api.openai.com"] {
            if _pinnedHosts[host] == nil {
                _pinnedHosts[host] = defaults
            }
        }
    }

    /// Resets the one-shot guard so `loadDefaultPins()` can be called again.
    /// Intended for tests only (`@testable import`).
    static func resetDefaultPinsForTesting() {
        _pinnedHostsLock.lock()
        defer { _pinnedHostsLock.unlock() }
        _defaultPinsLoaded = false
    }

    /// Hosts that bypass pinning entirely (local development servers).
    private static let bypassHosts: Set<String> = [
        "localhost", "127.0.0.1", "::1"
    ]
    
    /// Known production hosts that must have non-empty pin sets configured.
    private static let requiredPinnedHosts: Set<String> = [
        "api.openai.com",
        "api.anthropic.com"
    ]

    // MARK: - URLSessionDelegate

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // Bypass pinning for localhost / local network servers.
        if Self.bypassHosts.contains(host) {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let pins = Self.pinnedHosts[host]
        if Self.requiredPinnedHosts.contains(host) {
            guard let requiredPins = pins, !requiredPins.isEmpty else {
                Log.network.error("PinnedSessionDelegate: no certificate pins configured for required production host \(host, privacy: .public). Cancelling authentication challenge (fail-closed).")
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        }

        // If no pins are configured for a custom host, apply the configured trust policy.
        guard let expectedPins = pins, !expectedPins.isEmpty else {
            switch BaseChatConfiguration.shared.customHostTrustPolicy {
            case .platformDefault:
                Log.network.warning("PinnedSessionDelegate: no pins configured for custom host \(host, privacy: .public). Falling back to default trust evaluation.")
                completionHandler(.performDefaultHandling, nil)
            case .requireExplicitPins:
                Log.network.error("PinnedSessionDelegate: no certificate pins configured for custom host \(host, privacy: .public) and requireExplicitPins policy is active. Cancelling authentication challenge (fail-closed).")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            Log.network.error("PinnedSessionDelegate: missing server trust for pinned host \(host, privacy: .public). Cancelling authentication challenge.")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Evaluate the trust chain first.
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            Log.network.error("Certificate trust evaluation failed for \(host): \(error?.localizedDescription ?? "unknown")")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Check every certificate in the chain (leaf, intermediates, root) against
        // the pin set. This lets us pin intermediates or roots — more stable than
        // leaf-only pinning because individual server certs rotate frequently.
        guard let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              !certChain.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var seenHashes: [String] = []
        for certificate in certChain {
            guard let base64Hash = Self.spkiHashBase64(for: certificate) else {
                continue
            }
            seenHashes.append(base64Hash)

            if expectedPins.contains(base64Hash) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        Log.network.error("Certificate pin mismatch for \(host). No certificate in chain matched any of \(expectedPins.count) pins. Seen hashes: \(seenHashes.joined(separator: ", "))")
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    // MARK: - Helpers

    static func spkiHashBase64(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate),
              let rawKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
              let keyType = attributes[kSecAttrKeyType] as? String,
              let keySize = attributes[kSecAttrKeySizeInBits] as? Int,
              let spki = spkiDER(rawPublicKey: rawKeyData, keyType: keyType, keySizeInBits: keySize) else {
            return nil
        }
        return sha256(data: spki).base64EncodedString()
    }

    static func spkiDER(rawPublicKey: Data, keyType: String, keySizeInBits: Int) -> Data? {
        let algorithmIdentifier: Data
        if keyType == (kSecAttrKeyTypeRSA as String) {
            algorithmIdentifier = derSequence(
                concat(derObjectIdentifier([1, 2, 840, 113549, 1, 1, 1]), derNull())
            )
        } else if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            guard let curveOID = ecCurveOID(keySizeInBits: keySizeInBits) else {
                return nil
            }
            algorithmIdentifier = derSequence(
                concat(derObjectIdentifier([1, 2, 840, 10045, 2, 1]), curveOID)
            )
        } else {
            return nil
        }

        return derSequence(concat(algorithmIdentifier, derBitString(rawPublicKey)))
    }

    private static func ecCurveOID(keySizeInBits: Int) -> Data? {
        switch keySizeInBits {
        case 256:
            return derObjectIdentifier([1, 2, 840, 10045, 3, 1, 7])
        case 384:
            return derObjectIdentifier([1, 3, 132, 0, 34])
        case 521:
            return derObjectIdentifier([1, 3, 132, 0, 35])
        default:
            return nil
        }
    }

    private static func derSequence(_ content: Data) -> Data {
        derTLV(tag: 0x30, content: content)
    }

    private static func derBitString(_ content: Data) -> Data {
        derTLV(tag: 0x03, content: concat(Data([0x00]), content))
    }

    private static func derNull() -> Data {
        Data([0x05, 0x00])
    }

    private static func derObjectIdentifier(_ components: [UInt64]) -> Data {
        precondition(components.count >= 2, "OID requires at least two components")
        precondition(components[0] <= 2, "OID first component must be 0, 1, or 2")
        precondition(components[1] <= 39 || components[0] == 2, "OID second component out of range")

        var body = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            body.append(contentsOf: derBase128(component))
        }
        return derTLV(tag: 0x06, content: body)
    }

    private static func derBase128(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes = [UInt8(remaining & 0x7F)]
        remaining >>= 7
        while remaining > 0 {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        return Array(bytes.reversed())
    }

    private static func derTLV(tag: UInt8, content: Data) -> Data {
        var data = Data([tag])
        data.append(derLength(content.count))
        data.append(content)
        return data
    }

    private static func derLength(_ length: Int) -> Data {
        precondition(length >= 0, "DER length cannot be negative")
        if length < 0x80 {
            return Data([UInt8(length)])
        }

        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.append(UInt8(value & 0xFF))
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + Array(bytes.reversed()))
    }

    private static func concat(_ parts: Data...) -> Data {
        var data = Data()
        for part in parts {
            data.append(part)
        }
        return data
    }

    private static func sha256(data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }
}

#endif
