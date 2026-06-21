import XCTest
@testable import ManifoldOllama
@testable import ManifoldInference

/// Tests for the owned-policy → advisory-residency bridge (#1931).
///
/// `OllamaBackend` keeps a model resident **server-side** (in VRAM) on its own
/// `keep_alive` timer — MK cannot evict it directly, only advise. This suite
/// verifies the translation from MK's owned ``KeepAlivePolicy/idleTimeout`` into
/// the wire `keep_alive` string Ollama receives, so the two residency horizons
/// agree instead of diverging.
@MainActor
final class OllamaKeepAliveBridgeTests: XCTestCase {

    func test_applyAdvisoryKeepAlive_translatesSecondsExactly() {
        let backend = OllamaBackend()
        backend.applyAdvisoryKeepAlive(idleTimeout: 300)
        XCTAssertEqual(
            backend.keepAlive,
            "300s",
            "A 300s owned idle timeout must be advised to Ollama as \"300s\""
        )

        // Sabotage check: confirm the value is actually derived from the input,
        // not a constant. A different timeout must produce a different string.
        backend.applyAdvisoryKeepAlive(idleTimeout: 600)
        XCTAssertEqual(backend.keepAlive, "600s")
        XCTAssertNotEqual(backend.keepAlive, "300s")
    }

    func test_applyAdvisoryKeepAlive_roundsFractionalUp() {
        let backend = OllamaBackend()
        backend.applyAdvisoryKeepAlive(idleTimeout: 0.5)
        // Ollama parses integer seconds; a sub-second timeout rounds up so the
        // server doesn't truncate it to "0s" and unload immediately.
        XCTAssertEqual(backend.keepAlive, "1s")
    }

    func test_applyAdvisoryKeepAlive_clampsNonPositiveToZero() {
        let backend = OllamaBackend()
        backend.applyAdvisoryKeepAlive(idleTimeout: -10)
        XCTAssertEqual(backend.keepAlive, "0s", "A non-positive timeout clamps to \"0s\" (Ollama unloads immediately)")
    }

    func test_applyAdvisoryKeepAlive_nilLeavesDefault() {
        let backend = OllamaBackend()
        let original = backend.keepAlive
        XCTAssertEqual(original, "30m", "Precondition: the default keep_alive is 30m")

        // .never (idleTimeout == nil) gives no advice — the backend keeps its own
        // default residency.
        backend.applyAdvisoryKeepAlive(idleTimeout: nil)
        XCTAssertEqual(backend.keepAlive, original, "A nil (.never) timeout must not overwrite the default keep_alive")
    }

    func test_ollamaBackend_conformsToAdvisoryResidencyConfigurable() {
        // The coordinator only bridges when the backend opts in via the protocol;
        // guard the conformance so a future refactor can't silently drop it.
        XCTAssertTrue(OllamaBackend() is AdvisoryResidencyConfigurable)
    }
}
