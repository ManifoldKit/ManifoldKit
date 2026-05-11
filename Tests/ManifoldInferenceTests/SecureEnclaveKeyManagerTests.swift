import XCTest
import Foundation
@testable import ManifoldInference
import ManifoldTestSupport

// Tests for SecureEnclaveKeyManager and SecureEnclaveKeyStoreProtocol.
//
// Tests that exercise the Keychain / hardware SE path are still present and
// still skip gracefully when entitlements are absent (simulator or ad-hoc
// signed `swift test` binaries).  The protocol-level tests now run against
// the injected MockSecureEnclaveKeyStore so that CI always exercises the
// crypto logic, regardless of Keychain availability.
final class SecureEnclaveKeyManagerTests: XCTestCase {

    // MARK: - Protocol-level tests (always run)

    // A fresh MockSecureEnclaveKeyStore per test case keeps state isolated.
    private var store: MockSecureEnclaveKeyStore!

    override func setUp() {
        super.setUp()
        store = MockSecureEnclaveKeyStore()
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func testWrapProducesNonEmptyCiphertext() throws {
        let payload = Data("sk-test-secret".utf8)
        let wrapped = try store.wrapForStorage(payload)
        XCTAssertFalse(wrapped.isEmpty, "Wrapped ciphertext must not be empty")
        XCTAssertNotEqual(wrapped, payload, "Ciphertext must not equal plaintext")
    }

    func testUnwrapRoundTrip() throws {
        let payload = Data("sk-round-trip-\(UUID().uuidString)".utf8)
        let wrapped = try store.wrapForStorage(payload)
        let recovered = try store.unwrapFromStorage(wrapped)
        XCTAssertEqual(recovered, payload, "Round-tripped payload must equal original")
    }

    func testUnwrapRejectsCorruptedCiphertext() throws {
        let payload = Data("sk-test-payload".utf8)
        var wrapped = try store.wrapForStorage(payload)
        // Flip the last byte so the GCM authentication tag fails.
        wrapped[wrapped.index(before: wrapped.endIndex)] ^= 0xFF
        do {
            _ = try store.unwrapFromStorage(wrapped)
            XCTFail("Expected unwrapFromStorage to throw on tampered ciphertext")
        } catch SecureEnclaveError.operationFailed {
            // Expected
        }
    }

    func testWrapProducesDifferentCiphertextsForSamePlaintext() throws {
        // AES-GCM uses a random nonce, so each seal call must produce distinct ciphertext.
        let payload = Data("stable-payload".utf8)
        let first = try store.wrapForStorage(payload)
        let second = try store.wrapForStorage(payload)
        XCTAssertNotEqual(first, second, "Two wraps of the same plaintext must produce distinct ciphertexts")
    }

    func testEmptyPayloadRoundTrip() throws {
        let payload = Data()
        let wrapped = try store.wrapForStorage(payload)
        let recovered = try store.unwrapFromStorage(wrapped)
        XCTAssertEqual(recovered, payload, "Empty payload must round-trip correctly")
    }

    func testLargePayloadRoundTrip() throws {
        // 64 KB payload — exercises multi-block behaviour.
        let payload = Data(repeating: 0xAB, count: 65_536)
        let wrapped = try store.wrapForStorage(payload)
        let recovered = try store.unwrapFromStorage(wrapped)
        XCTAssertEqual(recovered, payload, "Large payload must round-trip correctly")
    }

    func testGetOrCreatePrivateKeyThrowsOnMock() {
        // The mock does not vend SecKey; it must throw operationFailed, not notAvailable.
        do {
            _ = try store.getOrCreatePrivateKey()
            XCTFail("Expected getOrCreatePrivateKey to throw on MockSecureEnclaveKeyStore")
        } catch SecureEnclaveError.operationFailed {
            // Expected — the mock is not backed by a real SE key.
        } catch {
            XCTFail("Expected SecureEnclaveError.operationFailed, got \(error)")
        }
    }

    // MARK: - Hardware / Keychain-backed tests
    //
    // These tests use SecureEnclaveKeyManager.shared directly and require both
    // hardware SE support *and* Keychain entitlements.  They skip when either
    // condition is absent (simulator, ad-hoc signed swift test binaries).

    func testIsAvailableReturnsFalseInSimulator() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(SecureEnclaveKeyManager.isAvailable)
        #else
        // On device/Mac we just verify it doesn't crash; availability depends on hardware.
        _ = SecureEnclaveKeyManager.isAvailable
        #endif
    }

    func testHardwareWrapForStorage() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Secure Enclave unavailable in simulator")
        #else
        try XCTSkipIf(
            !SecureEnclaveKeyManager.isAvailable,
            "Secure Enclave not available on this hardware"
        )
        let payload = Data("sk-test-secret".utf8)
        do {
            let wrapped = try SecureEnclaveKeyManager.shared.wrapForStorage(payload)
            XCTAssertFalse(wrapped.isEmpty)
        } catch SecureEnclaveError.notAvailable {
            throw XCTSkip("Secure Enclave not available (no Keychain entitlement in this environment)")
        }
        #endif
    }

    func testHardwareUnwrapRoundTrip() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Secure Enclave unavailable in simulator")
        #else
        try XCTSkipIf(
            !SecureEnclaveKeyManager.isAvailable,
            "Secure Enclave not available on this hardware"
        )
        let payload = Data("sk-round-trip-\(UUID().uuidString)".utf8)
        do {
            let wrapped = try SecureEnclaveKeyManager.shared.wrapForStorage(payload)
            let recovered = try SecureEnclaveKeyManager.shared.unwrapFromStorage(wrapped)
            XCTAssertEqual(recovered, payload)
        } catch SecureEnclaveError.notAvailable {
            throw XCTSkip("Secure Enclave not available (no Keychain entitlement in this environment)")
        }
        #endif
    }

    func testHardwareGetOrCreatePrivateKey() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Secure Enclave unavailable in simulator")
        #else
        try XCTSkipIf(
            !SecureEnclaveKeyManager.isAvailable,
            "Secure Enclave not available on this hardware"
        )
        do {
            let key = try SecureEnclaveKeyManager.shared.getOrCreatePrivateKey()
            XCTAssertNotNil(key)
        } catch SecureEnclaveError.notAvailable {
            throw XCTSkip("Secure Enclave not available (no Keychain entitlement in this environment)")
        }
        #endif
    }

    func testHardwareRoundTripWrapUnwrap() throws {
        try XCTSkipIf(
            !SecureEnclaveKeyManager.isAvailable,
            "Secure Enclave not available (simulator or unsupported hardware)"
        )
        let payload = Data("api-key-payload-\(UUID().uuidString)".utf8)
        do {
            let wrapped = try SecureEnclaveKeyManager.shared.wrapForStorage(payload)
            let recovered = try SecureEnclaveKeyManager.shared.unwrapFromStorage(wrapped)
            XCTAssertEqual(recovered, payload, "Wrapped/unwrapped payload must match original")
            XCTAssertNotEqual(wrapped, payload, "Wrapped data should not equal plaintext")
        } catch SecureEnclaveError.notAvailable {
            throw XCTSkip("Secure Enclave not available (no Keychain entitlement in this environment)")
        }
    }

    // MARK: - Always-run shared tests

    func testEvictCachedKeyDoesNotCrash() {
        // Should be safe to call regardless of SE availability.
        SecureEnclaveKeyManager.shared.evictCachedKey()
    }

    func testSecureEnclaveErrorDescriptions() {
        let notAvail = SecureEnclaveError.notAvailable
        XCTAssertFalse(notAvail.errorDescription?.isEmpty ?? true)

        let genFailed = SecureEnclaveError.keyGenerationFailed("test reason")
        XCTAssertTrue(genFailed.errorDescription?.contains("test reason") ?? false)

        let opFailed = SecureEnclaveError.operationFailed("op reason")
        XCTAssertTrue(opFailed.errorDescription?.contains("op reason") ?? false)
    }
}
