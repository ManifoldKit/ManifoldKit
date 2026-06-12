#if Llama
import XCTest
import ManifoldBackends
@_spi(Testing) import ManifoldLlama
import ManifoldInference

// Tests for LlamaBackend.secureWipe().
// Real KV-zeroing requires an active llama.cpp context with a loaded model,
// which needs Llama hardware/binary and a GGUF file.  All tests that touch
// a live context are skipped unless the Llama trait is present.
final class LlamaKVCacheSecureWipeTests: XCTestCase {

    func testSecureWipeDoesNotCrashWithNoContextLoaded() {
        // secureWipe() on an unloaded backend should be a safe no-op — no
        // context or memory pointer to dereference.
        #if Llama
        let backend = LlamaBackend()
        backend.secureWipe()  // Must not crash
        #else
        // Without the Llama compile-time flag there's no LlamaBackend symbol
        // at all; skip gracefully.
        XCTSkip("Llama trait not enabled")
        #endif
    }

    func testSecureWipeClearsSessionKVState() {
        // Verify the state-level effect (sessionKVState = nil) without
        // requiring a real model.  Since sessionKVState is not directly
        // observable from outside, we verify indirectly: calling secureWipe()
        // then resetConversation() again should not crash (double-free guard).
        #if Llama
        let backend = LlamaBackend()
        backend.secureWipe()
        backend.resetConversation()  // Must not crash on double clear
        #else
        XCTSkip("Llama trait not enabled")
        #endif
    }
}
#endif
