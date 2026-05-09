import XCTest
import Foundation
@testable import ManifoldInference

// Tests for SecureEnclaveKeyManager.
// The SE is unavailable in the simulator, so hardware-specific tests are
// skipped automatically via XCTSkipIf.
final class SecureEnclaveKeyManagerTests: XCTestCase {

    func testIsAvailableReturnsFalseInSimulator() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(SecureEnclaveKeyManager.isAvailable)
        #else
        // On device/Mac we just verify it doesn't crash; availability depends on hardware.
        _ = SecureEnclaveKeyManager.isAvailable
        #endif
    }

    func testWrapForStorageThrowsNotAvailableInSimulator() async throws {
        #if targetEnvironment(simulator)
        let payload = Data("sk-test-secret".utf8)
        do {
            _ = try SecureEnclaveKeyManager.shared.wrapForStorage(payload)
            XCTFail("Expected SecureEnclaveError.notAvailable")
        } catch SecureEnclaveError.notAvailable {
            // Expected
        }
        #else
        try XCTSkipIf(!SecureEnclaveKeyManager.isAvailable, "Secure Enclave not available on this hardware")
        // On capable hardware the call should succeed (or throw notAvailable if no entitlement)
        let payload = Data("sk-test-secret".utf8)
        do {
            let wrapped = try SecureEnclaveKeyManager.shared.wrapForStorage(payload)
            XCTAssertFalse(wrapped.isEmpty)
        } catch SecureEnclaveError.notAvailable {
            throw XCTSkip("Secure Enclave not available (no Keychain entitlement in this environment)")
        }
        #endif
    }

    func testUnwrapFromStorageThrowsNotAvailableInSimulator() async throws {
        #if targetEnvironment(simulator)
        let garbage = Data("not-a-ciphertext".utf8)
        do {
            _ = try SecureEnclaveKeyManager.shared.unwrapFromStorage(garbage)
            XCTFail("Expected SecureEnclaveError.notAvailable")
        } catch SecureEnclaveError.notAvailable {
            // Expected
        }
        #else
        try XCTSkipIf(!SecureEnclaveKeyManager.isAvailable, "Secure Enclave not available on this hardware")
        // wrap then unwrap round-trip
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

    func testGetOrCreatePrivateKeyThrowsNotAvailableInSimulator() async throws {
        #if targetEnvironment(simulator)
        do {
            _ = try SecureEnclaveKeyManager.shared.getOrCreatePrivateKey()
            XCTFail("Expected SecureEnclaveError.notAvailable")
        } catch SecureEnclaveError.notAvailable {
            // Expected
        }
        #else
        try XCTSkipIf(!SecureEnclaveKeyManager.isAvailable, "Secure Enclave not available on this hardware")
        do {
            let key = try SecureEnclaveKeyManager.shared.getOrCreatePrivateKey()
            XCTAssertNotNil(key)
        } catch SecureEnclaveError.notAvailable {
            throw XCTSkip("Secure Enclave not available (no Keychain entitlement in this environment)")
        }
        #endif
    }

    func testRoundTripWrapUnwrapOnDevice() throws {
        try XCTSkipIf(!SecureEnclaveKeyManager.isAvailable,
            "Secure Enclave not available (simulator or unsupported hardware)")
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
