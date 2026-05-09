import XCTest
import Foundation
@testable import ManifoldInference

// Tests for KeychainService.retrieveSecure(account:).
// These tests write a real Keychain item and verify that retrieveSecure returns
// a SecureBytes containing the same UTF-8 bytes as retrieve returns a String.
// Tests are integration tests — they write to the real Keychain under a
// test-specific service name scoped to this test process.
final class KeychainServiceSecureRetrieveTests: XCTestCase {

    private let testAccount = "com.manifoldkit.tests.secureretrieve.\(UUID().uuidString)"

    override func tearDown() async throws {
        try? KeychainService.delete(account: testAccount)
        try await super.tearDown()
    }

    func testRetrieveSecureReturnsSameBytesAsRetrieve() throws {
        let testKey = "sk-test-\(UUID().uuidString)"
        try KeychainService.store(key: testKey, account: testAccount)

        let plain = KeychainService.retrieve(account: testAccount)
        let secure = KeychainService.retrieveSecure(account: testAccount)

        XCTAssertEqual(plain, testKey)
        XCTAssertNotNil(secure)
        XCTAssertEqual(secure?.stringValue, testKey)
    }

    func testRetrieveSecureReturnsNilForMissingAccount() {
        let result = KeychainService.retrieveSecure(account: "nonexistent-\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    func testRetrieveSecureHandlesNonASCIIKeys() throws {
        // Verify round-trip fidelity for UTF-8 content (e.g. accented chars).
        let testKey = "sk-clé-\(UUID().uuidString)"
        try KeychainService.store(key: testKey, account: testAccount)
        let secure = KeychainService.retrieveSecure(account: testAccount)
        XCTAssertEqual(secure?.stringValue, testKey)
    }

    #if DEBUG
    func testRetrieveSecureBufferIsZeroedOnDealloc() throws {
        let testKey = "sk-zerocheck-\(UUID().uuidString)"
        try KeychainService.store(key: testKey, account: testAccount)

        var observedZero = false
        do {
            let secure = try XCTUnwrap(KeychainService.retrieveSecure(account: testAccount))
            secure._testingOnZeroed = { buf in
                observedZero = buf.allSatisfy { $0 == 0 }
            }
        }
        XCTAssertTrue(observedZero, "SecureBytes buffer must be zero-filled after deallocation")
    }
    #endif
}
