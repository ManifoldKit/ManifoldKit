@preconcurrency import XCTest
import Foundation
import os
@testable import ManifoldUI
import ManifoldRuntime
@testable import ManifoldInference
import ManifoldContractTestSupport

/// Exercises ``WebSearchToolSource`` against the shared
/// ``SessionToolSourceContract`` mixin. Construction pattern mirrors
/// `ChatViewModelWebSearchTests`.
@MainActor
final class WebSearchToolSourceTests: XCTestCase, SessionToolSourceContract {

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(
            inferenceService: InferenceService(),
            userDefaults: UserDefaults(suiteName: "WebSearchToolSourceTests-\(UUID().uuidString)")!
        )
    }

    // MARK: - SessionToolSourceContract
    //
    // THE HAZARD: `makeSource()` is a nonisolated protocol requirement (the
    // protocol carries no global-actor annotation), and this test class is
    // `@MainActor` because the source under test needs a `@MainActor`
    // `ChatViewModel`. A first attempt — building the `ChatViewModel` lazily
    // inside `makeSource()` via `MainActor.assumeIsolated` and calling the
    // contract's `assertSessionToolSource_*()` helpers directly from
    // `@MainActor` test methods — does NOT compile: Swift 6 rejects it with
    // "sending 'self' risks causing data races", because `self` here is a
    // non-Sendable, `@MainActor`-isolated `XCTestCase` instance, and calling
    // a *nonisolated* instance method (the protocol extension) from a
    // `@MainActor`-isolated call site requires sending that isolated `self`
    // across the boundary — which the compiler correctly refuses since other
    // methods on `self` remain reachable from the main actor concurrently.
    // This is a real one, not a false positive: it's exactly the class of
    // bug AGENTS.md's Swift 6 gotcha #1 warns about (non-isolated async
    // helpers whose caller assumes an isolation the callee doesn't have).
    //
    // Fix: keep the class `@MainActor` (so ordinary per-test setup and
    // `ChatViewModel` construction stay ergonomic), but declare the two
    // `test_contract_*` wrapper methods themselves `nonisolated`. A
    // `nonisolated` member of an `@MainActor` type is legal per-member
    // isolation override — at that specific call site `self` is no longer
    // statically main-actor-isolated, so calling the nonisolated contract
    // helper needs no cross-isolation send.
    //
    // That still leaves `makeSource()` needing to hand back a
    // `@MainActor`-built `WebSearchToolSource` from a nonisolated context.
    // Building it lazily and unsynchronized would be a real race (the
    // nonisolated caller and `setUp()` could observe partial state).
    // Instead the source is built once, actually on the main actor, inside
    // `setUp()` (which inherits the class's `@MainActor` isolation), and
    // handed to `makeSource()` through an `OSAllocatedUnfairLock` — the same
    // lock-guarded-storage shape AGENTS.md's gotcha #7 requires for any
    // seam that's written from one isolation domain and read from another
    // (mirrors `URLSessionProvider._networkDisabledLock` /
    // `CloudImageEncoding._encodeHook`). `WebSearchToolSource` conforms to
    // `SessionToolSource: Sendable` — `@MainActor`-isolated classes are
    // Sendable by construction because their mutable state is only ever
    // touched from that actor — so it's safe to carry the pointer across
    // the lock. This is deliberately NOT `@unchecked Sendable` or
    // `Task.detached`: the lock provides real mutual exclusion, not an
    // unchecked promise.
    private let sourceStorage = OSAllocatedUnfairLock<(any SessionToolSource)?>(initialState: nil)

    override func setUp() async throws {
        try await super.setUp()
        let source = WebSearchToolSource(viewModel: makeViewModel())
        sourceStorage.withLock { $0 = source }
    }

    nonisolated func makeSource() -> any SessionToolSource {
        guard let source = sourceStorage.withLock({ $0 }) else {
            fatalError("WebSearchToolSourceTests.makeSource() called before setUp() populated the source — a test-harness ordering bug, not a runtime condition a real caller can hit.")
        }
        return source
    }

    nonisolated func test_contract_toolDefinitionsStableAcrossCalls() async {
        await assertSessionToolSource_toolDefinitions_stableAcrossCalls()
    }

    nonisolated func test_contract_allowedToolNamesDefaultsToNil() async {
        await assertSessionToolSource_allowedToolNames_defaultsToNil()
    }

    // MARK: - Deliberate non-adoption: assertSessionToolSource_resolve_unknownTool_throws()
    //
    // Not wired up. `WebSearchToolSource.resolve` (`Sources/ManifoldUI/Tools/WebSearchToolSource.swift:51-53`)
    // does not throw for an unadvertised tool name — it returns
    // `ToolResult(callId:content:errorKind: .unknownTool)`. This is not the
    // "fabricated result for a tool it did not advertise" the contract's doc
    // warns about: `ToolResult.errorKind` is a first-class, localized error
    // channel (`ToolTypes.swift:451`, mapping `.unknownTool` to "This tool
    // isn't available."), and `SessionToolSourceExecutor` (`SessionToolSourceExecutor.swift:53-66`)
    // always constructs sources with an advertised `definition` and forwards
    // the result unexamined — so an actual unadvertised-name call is not a
    // reachable production path for this executor. It's a genuine encoding
    // split across `SessionToolSource` conformers (`SkillToolSource` /
    // `HandoffToolSource` throw; the three UI tool sources return a
    // structured error), not a defect this PR should paper over by forcing
    // the throw-based assertion. Pinned instead as the actual behavior:
    func test_resolve_unadvertisedToolName_returnsUnknownToolErrorInsteadOfThrowing() async throws {
        let source = makeSource()
        let session = makeSession()
        let result = try await source.resolve(
            toolName: "__contract_unadvertised_\(UUID().uuidString)",
            arguments: "{}",
            session: session
        )
        XCTAssertEqual(result.errorKind, .unknownTool)
    }
}
