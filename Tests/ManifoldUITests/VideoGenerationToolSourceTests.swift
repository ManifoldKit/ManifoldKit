@preconcurrency import XCTest
import Foundation
import os
@testable import ManifoldUI
import ManifoldRuntime
@testable import ManifoldInference
import ManifoldContractTestSupport

/// Coverage for gap B of the UI-honesty audit (#2356): before this fix,
/// ``VideoGenerationToolSource`` unconditionally told the model "Video
/// generation started" — even when no ``VideoGenerationRuntime`` was
/// installed — and swallowed fire-and-forget failures into a log-only
/// warning.
@MainActor
final class VideoGenerationToolSourceTests: XCTestCase, SessionToolSourceContract {

    // MARK: - SessionToolSourceContract
    //
    // See `WebSearchToolSourceTests`'s `sourceStorage`/`makeSource()`
    // comment for the full isolation rationale: `makeSource()` is a
    // nonisolated protocol requirement, but this class is `@MainActor` and
    // `VideoGenerationToolSource` needs a `@MainActor` `ChatViewModel`.
    // Calling the contract's nonisolated `assertSessionToolSource_*()`
    // helpers directly from an `@MainActor` test method does NOT compile
    // (Swift 6 "sending 'self' risks causing data races" — self is a
    // non-Sendable `@MainActor`-isolated `XCTestCase`). Fix: the two
    // `test_contract_*` wrapper methods are `nonisolated` per-member
    // overrides so `self` isn't sent across an isolation boundary at that
    // call site, and the actually-`@MainActor`-built source is handed
    // across via an `OSAllocatedUnfairLock` populated once in `setUp()` —
    // real mutual exclusion, not `@unchecked Sendable` or `Task.detached`.
    private let sourceStorage = OSAllocatedUnfairLock<(any SessionToolSource)?>(initialState: nil)

    override func setUp() async throws {
        try await super.setUp()
        let source = VideoGenerationToolSource(viewModel: ChatViewModel())
        sourceStorage.withLock { $0 = source }
    }

    nonisolated func makeSource() -> any SessionToolSource {
        guard let source = sourceStorage.withLock({ $0 }) else {
            fatalError("VideoGenerationToolSourceTests.makeSource() called before setUp() populated the source — a test-harness ordering bug, not a runtime condition a real caller can hit.")
        }
        return source
    }

    nonisolated func test_contract_toolDefinitionsStableAcrossCalls() async {
        await assertSessionToolSource_toolDefinitions_stableAcrossCalls()
    }

    nonisolated func test_contract_allowedToolNamesDefaultsToNil() async {
        await assertSessionToolSource_allowedToolNames_defaultsToNil()
    }

    // NOTE: assertSessionToolSource_resolve_unknownTool_throws() is
    // deliberately NOT adopted — see `test_resolve_unknownTool_stillReturnsUnknownToolError`
    // below, which already pins the actual (non-throwing) behavior:
    // `resolve` returns a `ToolResult` with `errorKind: .unknownTool`
    // instead of throwing for an unrecognized tool name. That is a genuine
    // divergence from `SkillToolSource` / `HandoffToolSource`, not a test
    // gap; forcing the assertion would be permanently red. Flagged as a
    // finding in the PR body rather than papered over.

    // MARK: - Minimal fakes

    /// A `VideoGenerationBackend` whose stream ends immediately with no
    /// events — enough to construct a real `VideoGenerationService` /
    /// `VideoGenerationRuntime` pair without a network dependency. The tests
    /// below never let a generation reach this backend (they fail earlier,
    /// at the `.noActiveConversation` precondition), so its behavior beyond
    /// "conforms" is irrelevant.
    private final class StubVideoBackend: VideoGenerationBackend, @unchecked Sendable {
        func generate(
            prompt: String,
            config: VideoGenerationConfig
        ) async throws -> AsyncThrowingStream<VideoGenerationEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func cancel() async {}
    }

    /// Bare in-memory `MessageStore` — only exists to satisfy
    /// `VideoGenerationRuntime`'s initializer; no test below reaches a real
    /// insert/update.
    private final class StubMessageStore: MessageStore, @unchecked Sendable {
        func insertMessage(_ message: ChatMessage) async throws {}
        func updateMessage(_ message: ChatMessage) async throws {}
        func deleteMessage(_ messageID: UUID) async throws {}
        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] { [] }
        func deleteMessages(for sessionID: UUID) async throws {}
        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
    }

    private func makeConfiguredViewModel() -> ChatViewModel {
        let vm = ChatViewModel()
        let runtime = VideoGenerationRuntime(
            service: VideoGenerationService(backend: StubVideoBackend()),
            messageStore: StubMessageStore()
        )
        vm.configure(videoRuntime: runtime)
        return vm
    }

    // MARK: - Not configured: truthful error instead of the "started" lie

    func test_resolve_notConfigured_returnsPermanentErrorInsteadOfStartedClaim() async throws {
        let vm = ChatViewModel()
        XCTAssertNil(vm.videoRuntime, "Precondition: no VideoGenerationRuntime installed")
        let source = VideoGenerationToolSource(viewModel: vm)

        let result = try await source.resolve(
            toolName: "generate_video",
            arguments: #"{"prompt": "a lighthouse at dusk"}"#,
            session: ChatSession(title: "Test")
        )

        XCTAssertEqual(result.errorKind, .permanent, "Not-configured must be a permanent (non-retryable) tool error")
        XCTAssertFalse(
            // The original bug's exact lying phrase — the honest error text
            // legitimately uses the word "started" elsewhere (e.g. "cannot be
            // started"), so match the specific affirmative claim, not the bare word.
            result.content.lowercased().contains("generation started"),
            "Must not claim generation started when no video backend is configured: \(result.content)"
        )
    }

    /// Unknown tool name and malformed arguments still short-circuit before
    /// the preflight — unchanged behavior, pinned so the new guard didn't
    /// reorder these checks.
    func test_resolve_unknownTool_stillReturnsUnknownToolError() async throws {
        let vm = ChatViewModel()
        let source = VideoGenerationToolSource(viewModel: vm)

        let result = try await source.resolve(
            toolName: "not_a_real_tool",
            arguments: "{}",
            session: ChatSession(title: "Test")
        )

        XCTAssertEqual(result.errorKind, .unknownTool)
    }

    func test_resolve_missingPrompt_stillReturnsInvalidArgumentsError() async throws {
        let vm = ChatViewModel()
        let source = VideoGenerationToolSource(viewModel: vm)

        let result = try await source.resolve(
            toolName: "generate_video",
            arguments: "{}",
            session: ChatSession(title: "Test")
        )

        XCTAssertEqual(result.errorKind, .invalidArguments)
    }

    // MARK: - Configured but the fire-and-forget call fails: surfaced, not just logged

    func test_resolve_configuredButNoActiveConversation_surfacesErrorOnViewModel() async throws {
        let vm = makeConfiguredViewModel()
        XCTAssertNotNil(vm.videoRuntime, "Precondition: runtime IS configured, so this exercises the fire-and-forget path, not the preflight")
        XCTAssertNil(vm.activeSessionID, "Precondition: no active session — generateVideo() throws .noActiveConversation")
        XCTAssertNil(vm.activeError)

        let source = VideoGenerationToolSource(viewModel: vm)
        let result = try await source.resolve(
            toolName: "generate_video",
            arguments: #"{"prompt": "a lighthouse at dusk"}"#,
            session: ChatSession(title: "Test")
        )

        // resolve() itself still returns the optimistic "started" message —
        // it can't know the fire-and-forget Task will fail yet — but the
        // failure must become visible on the view model shortly after.
        XCTAssertNil(result.errorKind)

        let deadline = Date().addingTimeInterval(2)
        while vm.activeError == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNotNil(
            vm.activeError,
            "A failed fire-and-forget generateVideo() call must reach viewModel.surfaceError, not just Log.ui.warning"
        )
        XCTAssertEqual(vm.activeError?.kind, .generation)
    }
}
