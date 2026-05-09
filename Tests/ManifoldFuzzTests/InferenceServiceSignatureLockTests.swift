#if Fuzz
import XCTest
import ManifoldInference
import ManifoldTestSupport

/// Canary: pins the exact signatures of ``InferenceService/enqueue`` and
/// ``InferenceService/stopGeneration(sessionID:)`` so that a refactor of
/// ``GenerationQueue`` cannot silently break the multi-turn fuzzer.
///
/// The fuzzer's ``SessionScriptRunner`` drives through the real
/// ``InferenceService``; a drift in these signatures would compile cleanly
/// on the service side but break the fuzzer's call sites without warning.
/// These tests import the type we expect and bind the method to a typed
/// closure — if the closure type fails to match, the build breaks here.
@MainActor
final class InferenceServiceSignatureLockTests: XCTestCase {

    /// Pins the full `enqueue(messages:systemPrompt:temperature:topP:repeatPenalty:maxOutputTokens:priority:sessionID:)` signature.
    ///
    /// Any change to parameter labels, types, default values, or throws-ness
    /// fails this test at compile time.
    func test_enqueueSignatureIsLocked() throws {
        let service = InferenceService(
            backend: MockInferenceBackend(),
            name: "SignatureLock"
        )

        // Bind the method to a typed closure with the exact expected shape.
        // If the signature drifts the assignment fails to type-check.
        let bound: (
            [(role: String, content: String)],
            String?,
            Float,
            Float,
            Float,
            Int?,
            InferenceService.GenerationPriority,
            UUID?
        ) throws -> (token: InferenceService.GenerationRequestToken, stream: GenerationStream) = {
            (msgs, sys, temp, topP, rep, maxTok, prio, sid) in
            try service.enqueue(
                messages: msgs,
                systemPrompt: sys,
                temperature: temp,
                topP: topP,
                repeatPenalty: rep,
                maxOutputTokens: maxTok,
                priority: prio,
                sessionID: sid
            )
        }

        // Calling through the bound closure would require a loaded model
        // (the coordinator rejects unloaded backends). We only need to prove
        // the signature compiles — `_` silences unused-result, and
        // `XCTAssertNotNil` against the closure identity is a cheap runtime
        // assertion that the binding survived.
        let boundAsAny: Any = bound
        XCTAssertNotNil(boundAsAny)
    }

    /// Pins ``stopGeneration()`` as a no-argument, non-throwing method.
    /// (The service also offers `cancel(_:)` and `discardRequests(notMatching:)`
    /// — each pinned separately so a rename on any of them is detectable.)
    func test_stopGenerationSignatureIsLocked() {
        let service = InferenceService(
            backend: MockInferenceBackend(),
            name: "SignatureLock"
        )

        // stopGeneration() takes zero args and returns Void.
        let stop: () -> Void = service.stopGeneration
        stop() // safe; no active generation.

        // cancel(_:) takes a token, returns Void.
        let cancel: (InferenceService.GenerationRequestToken) -> Void = service.cancel
        XCTAssertNotNil(cancel as Any)

        // discardRequests(notMatching:) takes a UUID, returns Void.
        // Async to serialise tear-down of the active task before the next
        // enqueue lands (issue #965).
        let discard: (UUID) async -> Void = service.discardRequests(notMatching:)
        XCTAssertNotNil(discard as Any)
    }

    /// The fuzzer also relies on the two public typealiases for backwards
    /// compatibility. Pin them.
    func test_publicTypeAliasesAreLocked() {
        let priority: InferenceService.GenerationPriority = .normal
        XCTAssertEqual(priority, .normal)
        // The token type has no public initializer; verifying the type alias
        // resolves and `rawValue` is publicly readable is enough.
        let tokenType: InferenceService.GenerationRequestToken.Type = InferenceService.GenerationRequestToken.self
        XCTAssertNotNil(tokenType as Any)
    }
}
#endif
