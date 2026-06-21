import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Unit tests for sticky tool-approval (#1923 Part 1): the
/// ``ToolApprovalPolicy`` value type and the ``ToolApprovalHook`` factory
/// that layers it over the existing ``PreToolUseHook`` seam.
///
/// These exercise the policy → ``PreToolUseOutcome`` mapping in isolation
/// (no engine), counting host-prompt invocations. The "loop continues on a
/// decline" contract is asserted at the dispatch-loop level in
/// `ManifoldInferenceTests` (`ToolApprovalLoopContinuationTests`).
///
/// The sticky cache is run-scoped and in-memory (``ToolApprovalStickyCache``):
/// Part 1 deliberately persists nothing.
final class ToolApprovalPolicyTests: XCTestCase {

    // MARK: - Invocation counter

    /// Thread-safe counter for how many times the host approve prompt fired.
    /// `actor` because the hook closure is `@Sendable` and may run off the
    /// test's actor.
    private actor PromptCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    // MARK: - approveForRun: approve once, stick for the run

    func test_approveForRun_promptsOnceThenSticks() async throws {
        let counter = PromptCounter()
        let cache = ToolApprovalStickyCache()
        let hook = ToolApprovalHook.make(
            policy: .approveForRun(toolNames: ["search"]),
            cache: cache
        ) { _, _ in
            await counter.bump()
            return true
        }

        let callCount = 5
        for _ in 0..<callCount {
            let outcome = await hook("search", #"{"q":"swift"}"#, nil)
            guard case .proceed = outcome else {
                return XCTFail("approved tool must proceed, got \(outcome)")
            }
        }

        let prompts = await counter.count
        XCTAssertEqual(
            prompts, 1,
            "host approve prompt must fire exactly once across \(callCount) calls; subsequent calls hit the sticky cache"
        )
        let remembered = await cache.approvedTools()
        XCTAssertTrue(remembered.contains("search"), "the approved tool must be recorded in the sticky cache")
    }

    /// A tool not listed in `approveForRun` must prompt every time even though
    /// a *different* tool is sticky — stickiness is per-tool, not global.
    func test_approveForRun_unlistedToolPromptsEveryTime() async throws {
        let counter = PromptCounter()
        let hook = ToolApprovalHook.make(
            policy: .approveForRun(toolNames: ["search"])
        ) { _, _ in
            await counter.bump()
            return true
        }

        let callCount = 4
        for _ in 0..<callCount {
            _ = await hook("delete_file", "{}", nil)
        }

        let prompts = await counter.count
        XCTAssertEqual(prompts, callCount, "an unlisted tool must prompt on every call")
    }

    /// A *declined* call must NOT be remembered — the user keeps the chance to
    /// allow it on the next attempt.
    func test_approveForRun_declineIsNotSticky() async throws {
        let counter = PromptCounter()
        let cache = ToolApprovalStickyCache()
        let hook = ToolApprovalHook.make(
            policy: .approveForRun(toolNames: ["search"]),
            cache: cache
        ) { _, _ in
            await counter.bump()
            return false
        }

        for _ in 0..<3 {
            let outcome = await hook("search", "{}", nil)
            guard case .block = outcome else {
                return XCTFail("declined call must block, got \(outcome)")
            }
        }

        let prompts = await counter.count
        XCTAssertEqual(prompts, 3, "a decline must re-prompt — declines are not cached")
        let remembered = await cache.approvedTools()
        XCTAssertFalse(remembered.contains("search"), "a declined tool must not be recorded as approved")
    }

    // MARK: - alwaysAsk: prompt every time

    func test_alwaysAsk_promptsEveryCall() async throws {
        let counter = PromptCounter()
        let hook = ToolApprovalHook.make(policy: .alwaysAsk) { _, _ in
            await counter.bump()
            return true
        }

        let callCount = 4
        for _ in 0..<callCount {
            let outcome = await hook("search", "{}", nil)
            guard case .proceed = outcome else {
                return XCTFail("approved call must proceed")
            }
        }

        let prompts = await counter.count
        XCTAssertEqual(prompts, callCount, ".alwaysAsk must invoke the host on every call")
    }

    // MARK: - alwaysApprove: never prompt

    func test_alwaysApprove_neverPrompts() async throws {
        let counter = PromptCounter()
        let hook = ToolApprovalHook.make(policy: .alwaysApprove) { _, _ in
            await counter.bump()
            return true
        }

        let callCount = 4
        for _ in 0..<callCount {
            let outcome = await hook("search", #"{"q":"x"}"#, nil)
            guard case .proceed(let args) = outcome else {
                return XCTFail("alwaysApprove must proceed")
            }
            XCTAssertEqual(args, #"{"q":"x"}"#, "alwaysApprove forwards the model-emitted arguments unmodified")
        }

        let prompts = await counter.count
        XCTAssertEqual(prompts, 0, ".alwaysApprove must never consult the host prompt")
    }

    // MARK: - decline → typed block outcome

    /// A declined call maps to `.block`, carrying a denial reason. The
    /// dispatch loop turns this into a `permissionDenied` `ToolResult`
    /// (asserted end-to-end in `ToolApprovalLoopContinuationTests`).
    func test_decline_mapsToBlockOutcome() async throws {
        let hook = ToolApprovalHook.make(policy: .alwaysAsk) { _, _ in false }

        let outcome = await hook("danger", "{}", nil)
        guard case .block(let reason) = outcome else {
            return XCTFail("a declined call must map to .block, got \(outcome)")
        }
        XCTAssertNotNil(reason, "the block must carry a denial reason for the model")
    }
}
