@preconcurrency import XCTest
import Foundation
import SwiftData
import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatTestSupport

/// Perf-audit baseline (PR-β work unit β-3) for the `ConversationRuntime`
/// `touchSession` cost as session count grows.
///
/// `ConversationRuntime.touchSession(sessionStore:sessionID:)` updates the
/// `updatedAt` timestamp on a single session by:
///
/// 1. calling `sessionStore.fetchSessions()` (full-table scan, ordered by
///    `updatedAt`),
/// 2. linearly scanning the result to find the target session,
/// 3. mutating the local copy and calling `updateSession(_:)`.
///
/// At 10/100/500 sessions the full-fetch dominates the per-turn cost: every
/// `runtime.send` calls `touchSession` twice (before generation, after the
/// assistant write commits). The audit calls out a one-shot
/// `bumpUpdatedAt(id:)` SessionStore method as the natural fix; this test
/// produces the baseline that fix is measured against.
///
/// Nightly-gated — `RUN_SLOW_TESTS=1` to force locally; skipped on per-PR CI
/// to keep the budget flat. The 500-session iteration alone runs the full
/// `fetchSessions()` SwiftData query repeatedly and is too slow for the
/// default 5-minute CI window.
///
/// > Note on placement: this file lives in `BaseChatCoreTests` (not
/// > `BaseChatRuntimeTests` per the plan brief) because the in-memory
/// > SwiftData stack requires `BaseChatPersistenceSwiftData`, and the
/// > `BaseChatRuntimeTests` target is intentionally constrained to
/// > non-SwiftData dependencies (see Package.swift comment above the target).
@MainActor
final class TouchSessionScalePerformanceTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(
            env["CI"] == "true" && env["RUN_SLOW_TESTS"] != "1",
            "Nightly perf baseline — gated by RUN_SLOW_TESTS=1. Always runs locally."
        )
        stack = try InMemoryPersistenceHarness.make()
    }

    override func tearDown() async throws {
        stack = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    /// 10-session baseline. Establishes the floor for per-touch overhead
    /// independent of fetch-all amortisation.
    func test_touchSessionAt10Sessions() throws {
        let targetID = try seedSessions(count: 10)
        runMeasureTouch(provider: stack.provider, targetID: targetID)
    }

    /// 100-session intermediate. Exposes whether the cost trends linearly
    /// with N (full-table-scan signature) or sub-linearly (an indexed lookup
    /// would here).
    func test_touchSessionAt100Sessions() throws {
        let targetID = try seedSessions(count: 100)
        runMeasureTouch(provider: stack.provider, targetID: targetID)
    }

    /// 500-session worst-case for a power user. Concrete number from this
    /// test is the audit's primary input for prioritising the
    /// `bumpUpdatedAt(id:)` PR.
    func test_touchSessionAt500Sessions() throws {
        let targetID = try seedSessions(count: 500)
        runMeasureTouch(provider: stack.provider, targetID: targetID)
    }

    // MARK: - Measurement

    /// Drives the same sequence the runtime executes inside `touchSession`:
    /// fetch all, find the target, mutate, update. Invoking the runtime's
    /// private helper through `send` would conflate generation cost; the
    /// shape under measurement here is the audit's claim verbatim.
    private func runMeasureTouch(
        provider: SwiftDataPersistenceProvider,
        targetID: UUID
    ) {
        measure {
            let exp = expectation(description: "touch")
            Task { @MainActor in
                do {
                    let sessions = try await provider.fetchSessions()
                    if var session = sessions.first(where: { $0.id == targetID }) {
                        session.updatedAt = Date()
                        try await provider.updateSession(session)
                    }
                } catch {
                    XCTFail("touch failed: \(error)")
                }
                exp.fulfill()
            }
            wait(for: [exp], timeout: 30)
        }
    }

    // MARK: - Fixture

    /// Seeds `count` sessions with realistic metadata and returns a target
    /// session ID positioned roughly halfway through the list — the linear
    /// scan inside `touchSession` will iterate `count / 2` records on average
    /// to find it.
    private func seedSessions(count: Int) throws -> UUID {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var targetID: UUID = UUID()
        let targetIndex = count / 2
        let exp = expectation(description: "seed")
        Task { @MainActor in
            do {
                for i in 0..<count {
                    let record = ChatSessionRecord(
                        title: "Perf Session \(i)",
                        createdAt: base.addingTimeInterval(Double(i)),
                        updatedAt: base.addingTimeInterval(Double(i)),
                        systemPrompt: "You are perf-test session \(i)."
                    )
                    if i == targetIndex { targetID = record.id }
                    try await stack.provider.insertSession(record)
                }
            } catch {
                XCTFail("fixture insert failed: \(error)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 60)
        return targetID
    }
}
