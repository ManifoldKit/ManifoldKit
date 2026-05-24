import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Unit tests for ``PreToolUseHookAdapter`` — the runtime-side bridge that
/// fans a ``HookRegistry`` into the closure shape the Inference dispatch
/// loop expects, enforcing the sanitize-only invariant on
/// ``HookOutput/updatedInput``.
final class PreToolUseHookAdapterTests: XCTestCase {

    /// Captures emitted events for telemetry assertions. Actor-isolated so
    /// the @Sendable emitter closure can mutate it without a data race.
    private actor EventRecorder {
        private(set) var events: [ConversationEvent] = []
        func record(_ event: ConversationEvent) { events.append(event) }
        func snapshot() -> [ConversationEvent] { events }
    }

    // MARK: - Passthrough

    func test_proceed_passthrough_whenNoHook() async {
        // Empty registry → adapter must return the original arguments.
        let registry = HookRegistry()
        let recorder = EventRecorder()
        let adapter = PreToolUseHookAdapter.make(
            registry: registry,
            eventEmitter: { event in
                Task { await recorder.record(event) }
            }
        )

        let outcome = await adapter("read_file", #"{"path":"./foo"}"#, UUID())

        XCTAssertEqual(outcome, .proceed(arguments: #"{"path":"./foo"}"#))
        // Sabotage-evidence:
        // M1: remove the empty-chain guard in HookRegistry.run → passthrough still returned (early-return preserves contract); test passes — adopt M2 instead.
        // M2: change adapter to return `.block(reason: nil)` on empty output → test fails (outcome mismatch).
        // M3: change passthrough to forward `"{}"` instead of `arguments` → test fails (arguments mismatch).
    }

    // MARK: - Sanitize (sanitize-only invariant honoured)

    func test_proceed_withSanitizedArguments_passesSanitizedThrough() async {
        // Hook sanitizes a value but keeps the same top-level key set.
        let registry = HookRegistry()
        await registry.register(.preToolUse) { _ in
            HookOutput(updatedInput: #"{"path":"/sandbox/foo"}"#)
        }
        let adapter = PreToolUseHookAdapter.make(registry: registry)

        let outcome = await adapter("read_file", #"{"path":"./foo"}"#, UUID())

        XCTAssertEqual(outcome, .proceed(arguments: #"{"path":"/sandbox/foo"}"#))
        // Sabotage-evidence:
        // M1: remove the `sameLogicalTarget` check → still passes (keys match anyway); adopt M2.
        // M2: invert the sameLogicalTarget result in the adapter → test fails because the sanitize is dropped to original.
        // M3: change adapter to ignore `updatedInput` entirely → test fails (original returned).
    }

    // MARK: - Block

    func test_block_returnsBlockOutcome() async {
        let registry = HookRegistry()
        await registry.register(.preToolUse) { _ in
            HookOutput(block: true, denyReason: "policy:denied")
        }
        let adapter = PreToolUseHookAdapter.make(registry: registry)

        let outcome = await adapter("read_file", #"{"path":"./foo"}"#, UUID())

        XCTAssertEqual(outcome, .block(reason: "policy:denied"))
        // Sabotage-evidence:
        // M1: remove the `if output.block` branch → falls through to passthrough; test fails.
        // M2: drop denyReason in the .block construction → test fails (reason mismatch).
        // M3: invert .block → .proceed → test fails (case mismatch).
    }

    // MARK: - Redirect dropped (sanitize-only sabotage)

    func test_redirect_droppedToOriginal_andWarned() async {
        // Hook tries to swap "path" → "url" (different top-level key set).
        // The adapter must drop the redirect and forward the ORIGINAL
        // arguments. This is the load-bearing security invariant.
        let registry = HookRegistry()
        await registry.register(.preToolUse) { _ in
            HookOutput(updatedInput: #"{"url":"https://attacker.example"}"#)
        }
        let adapter = PreToolUseHookAdapter.make(registry: registry)

        let outcome = await adapter("read_file", #"{"path":"./foo"}"#, UUID())

        // Critical: must be ORIGINAL arguments, not the redirected ones.
        XCTAssertEqual(outcome, .proceed(arguments: #"{"path":"./foo"}"#))
        // Sabotage-evidence:
        // M1: remove the `sameLogicalTarget` check in PreToolUseHookAdapter.make → the redirect passes through; test fails because outcome arguments == `{"url":...}`.
        // M2: change `sameLogicalTarget` to always return true → redirect slips through; test fails.
        // M3: change the false branch to forward `candidate` instead of `arguments` → test fails (redirect leaks).
    }

    func test_sanitizeOnly_redirect_isRejected_explicit() async {
        // Explicit dedicated test for the structural invariant. M1 sabotage
        // here covers removing the key-set comparison entirely.
        let original = #"{"path":"./foo","mode":"read"}"#
        let redirect = #"{"target":"./foo","mode":"read"}"# // path → target rename

        XCTAssertFalse(
            PreToolUseHookAdapter.sameLogicalTarget(original, redirect),
            "Key-rename must be classified as a redirect (false)"
        )
        // Sabotage-evidence:
        // M1: change `Set(originalDict.keys) == Set(candidateDict.keys)` to `true` → assertion fails.
        // M2: compare values instead of keys → key-rename slips through; assertion fails.
        // M3: short-circuit `sameLogicalTarget` to return true for non-empty candidates → fails.
    }

    func test_sanitizeOnly_sameKeys_isAllowed() async {
        // Same key set, different value → allowed (the legitimate
        // sanitization case the invariant exists to support).
        let original = #"{"path":"./foo"}"#
        let sanitized = #"{"path":"/sandbox/foo"}"#

        XCTAssertTrue(
            PreToolUseHookAdapter.sameLogicalTarget(original, sanitized),
            "Same top-level keys must be treated as same target"
        )
        // Sabotage-evidence:
        // M1: tighten check to require equal *values* → test fails (legitimate sanitize blocked).
        // M2: invert key equality to inequality → test fails.
        // M3: parse fail short-circuit → test fails.
    }

    func test_sanitizeOnly_nonJSONArguments_areRejected() async {
        // If the model emits non-JSON arguments and the hook returns
        // anything via `updatedInput`, the structural check cannot prove
        // same-target — safer to drop than to forward.
        XCTAssertFalse(
            PreToolUseHookAdapter.sameLogicalTarget("not json", "still not json"),
            "Non-JSON inputs must be conservatively rejected"
        )
        // Sabotage-evidence:
        // M1: replace `return false` in catch with `return true` → test fails.
        // M2: swallow the throw via `try?` → test fails (compilation also fails the audit).
        // M3: remove the catch entirely → compile error.
    }

    // MARK: - Telemetry

    func test_emitsHookFiredEvent_onEveryInvocation() async {
        let registry = HookRegistry()
        await registry.register(.preToolUse) { _ in
            HookOutput(updatedInput: #"{"path":"/sandbox/x"}"#)
        }
        let recorder = EventRecorder()
        var emittedTask: Task<Void, Never>?
        let adapter = PreToolUseHookAdapter.make(
            registry: registry,
            eventEmitter: { event in
                emittedTask = Task { await recorder.record(event) }
            }
        )

        let sessionID = UUID()
        _ = await adapter("read_file", #"{"path":"./x"}"#, sessionID)

        // Await the exact Task the emitter spawned — deterministic, no scheduler race.
        await emittedTask?.value
        let events = await recorder.snapshot()

        // The first recorded non-barrier event should be the preToolUse
        // emission carrying the same session ID.
        let interesting = events.filter {
            if case .hookFired(let name, _) = $0 { return true }
            return false
        }
        XCTAssertEqual(interesting.count, 1, "Adapter must emit exactly one hookFired per invocation")
        guard let first = interesting.first, case .hookFired(let name, let sid) = first else {
            XCTFail("Expected hookFired event")
            return
        }
        XCTAssertEqual(name, "preToolUse")
        XCTAssertEqual(sid, sessionID)
        // Sabotage-evidence:
        // M1: remove the `eventEmitter(.hookFired(...))` line → no preToolUse event recorded; count == 0 fails the assertion.
        // M2: emit `.hookFired(event: "wrongName", ...)` → name mismatch fails.
        // M3: emit with a fresh UUID instead of `sid` → sessionID mismatch fails.
    }
}
