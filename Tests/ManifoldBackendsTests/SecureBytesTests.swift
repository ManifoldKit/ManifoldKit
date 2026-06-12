import Testing
import Foundation
@testable import ManifoldInference
@testable import ManifoldSecrets
@testable import ManifoldBackends

// Minimal payload handler for tests that exercise SSECloudBackend state directly.
private struct NoOpPayloadHandler: SSEPayloadHandler {
    func extractToken(from payload: String) -> String? { nil }
    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? { nil }
    func isStreamEnd(_ payload: String) -> Bool { false }
    func extractStreamError(from payload: String) -> Error? { nil }
}

@Suite("SecureBytes")
struct SecureBytesTests {

    @Test("returns nil for empty string")
    func emptyStringIsNil() {
        #expect(SecureBytes("") == nil)
    }

    @Test("round-trips a non-empty key")
    func roundTrip() throws {
        let key = "sk-test-abc123"
        let secure = try #require(SecureBytes(key))
        #expect(secure.stringValue == key)
    }

    @Test("round-trips a key containing multi-byte UTF-8 characters")
    func roundTripMultiByte() throws {
        let key = "sk-\u{1F511}key"
        let secure = try #require(SecureBytes(key))
        #expect(secure.stringValue == key)
    }

    #if DEBUG
    /// Verifies that `deinit` actually wipes the backing buffer via `memset_s`.
    /// Uses the `#if DEBUG` `_testingOnZeroed` seam to inspect the buffer
    /// while it is still valid memory but after `memset_s` has run, immediately
    /// before `deallocate`. If a future change accidentally drops `memset_s`
    /// (or a compiler ever elides it), the snapshot will retain the original
    /// plaintext and this assertion will fail.
    @Test("deinit zeroes the backing buffer before deallocation")
    func deinitZeroesBuffer() throws {
        let key = "sk-secret-zeroing-probe-XYZ"
        let expectedCount = key.utf8.count

        // Captured by the deinit-fired probe; wrapped in a class so the
        // closure can mutate it without violating Sendable/escaping rules.
        final class Snapshot {
            var bytes: [UInt8] = []
            var fired = false
        }
        let snapshot = Snapshot()

        // Scope the SecureBytes so it deinits at the end of the do-block.
        do {
            let secure = try #require(SecureBytes(key))
            #expect(secure.stringValue == key)
            secure._testingOnZeroed = { buffer in
                snapshot.fired = true
                snapshot.bytes = Array(buffer)
            }
        }

        #expect(snapshot.fired, "deinit probe should have fired")
        #expect(snapshot.bytes.count == expectedCount)
        #expect(snapshot.bytes.allSatisfy { $0 == 0 }, "buffer must be zeroed by memset_s before deallocate")

        // Belt-and-suspenders: the original plaintext must not survive.
        let recovered = String(decoding: snapshot.bytes, as: UTF8.self)
        #expect(recovered != key)
    }
    #endif
}

@Suite("SSECloudBackend ephemeralAPIKey")
struct EphemeralAPIKeyTests {

    private func makeBackend() -> SSECloudBackend {
        SSECloudBackend(
            defaultModelName: "test-model",
            urlSession: .shared,
            payloadHandler: NoOpPayloadHandler()
        )
    }

    @Test("stores and retrieves a key")
    func storeAndRetrieve() {
        let backend = makeBackend()
        backend.ephemeralAPIKey = "sk-abc"
        #expect(backend.ephemeralAPIKey == "sk-abc")
    }

    @Test("setting an empty string treats key as absent")
    func emptyStringBecomesNil() {
        let backend = makeBackend()
        backend.ephemeralAPIKey = ""
        #expect(backend.ephemeralAPIKey == nil)
    }

    @Test("key is nil after unloadModel")
    func clearedAfterUnload() async {
        let backend = makeBackend()
        let url = URL(string: "https://api.test")!
        backend.configure(baseURL: url, apiKey: "sk-abc", modelName: "test-model")
        #expect(backend.ephemeralAPIKey == "sk-abc")
        backend.unloadModel()
        #expect(backend.ephemeralAPIKey == nil)
    }

    @Test("resolveAPIKey returns ephemeral key when no keychain account set")
    func resolveReturnsEphemeral() {
        let backend = makeBackend()
        let url = URL(string: "https://api.test")!
        backend.configure(baseURL: url, apiKey: "sk-resolve-test", modelName: "test-model")
        #expect(backend.resolveAPIKey() == "sk-resolve-test")
    }

    @Test("replacing a key with nil releases the old value")
    func replaceWithNil() {
        let backend = makeBackend()
        backend.ephemeralAPIKey = "sk-old"
        backend.ephemeralAPIKey = nil
        #expect(backend.ephemeralAPIKey == nil)
    }
}
