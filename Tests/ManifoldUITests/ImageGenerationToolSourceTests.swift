@preconcurrency import XCTest
import Foundation
import os
@testable import ManifoldUI
import ManifoldRuntime
@testable import ManifoldInference
import ManifoldContractTestSupport

/// Coverage for the ``ImageGenerationToolSource`` not-configured alignment
/// (#2128 item E): before this fix the image source folded not-configured
/// into the same blanket `.transient` catch as genuine runtime failures, so
/// the model was told the failure was retryable when no image backend was
/// wired at all. Mirrors the #2356 `VideoGenerationToolSource` fix — a
/// truthful `.permanent` for not-configured, `.transient` reserved for real
/// runtime failures.
@MainActor
final class ImageGenerationToolSourceTests: XCTestCase, SessionToolSourceContract {

    // MARK: - SessionToolSourceContract
    //
    // See `WebSearchToolSourceTests`'s `sourceStorage`/`makeSource()`
    // comment for the full isolation rationale: `makeSource()` is a
    // nonisolated protocol requirement, but this class is `@MainActor` and
    // `ImageGenerationToolSource` needs a `@MainActor` `ChatViewModel`.
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
        let source = ImageGenerationToolSource(viewModel: ChatViewModel())
        sourceStorage.withLock { $0 = source }
    }

    nonisolated func makeSource() -> any SessionToolSource {
        guard let source = sourceStorage.withLock({ $0 }) else {
            fatalError("ImageGenerationToolSourceTests.makeSource() called before setUp() populated the source — a test-harness ordering bug, not a runtime condition a real caller can hit.")
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

    /// Bare in-memory `MessageStore` — only exists to satisfy
    /// `ImageGenerationRuntime`'s initializer; the configured-but-no-session
    /// test fails at the `.noActiveConversation` precondition before reaching
    /// a real insert.
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
        vm.configure(imageRuntime: ImageGenerationRuntime(
            service: ImageGenerationService(),
            messageStore: StubMessageStore()
        ))
        return vm
    }

    // MARK: - Not configured: permanent, not transient

    func test_resolve_notConfigured_returnsPermanentError() async throws {
        let vm = ChatViewModel()
        XCTAssertNil(vm.imageRuntime, "Precondition: no ImageGenerationRuntime installed")
        let source = ImageGenerationToolSource(viewModel: vm)

        let result = try await source.resolve(
            toolName: "generate_image",
            arguments: #"{"prompt": "a lighthouse at dusk"}"#,
            session: ChatSession(title: "Test")
        )

        XCTAssertEqual(result.errorKind, .permanent,
            "Not-configured must be a permanent (non-retryable) tool error, not .transient")
        XCTAssertFalse(
            result.content.lowercased().contains("generation started"),
            "Must not claim generation started when no image backend is configured: \(result.content)"
        )
    }

    // MARK: - Argument short-circuits (unchanged, pinned so the new guard didn't reorder them)

    func test_resolve_unknownTool_stillReturnsUnknownToolError() async throws {
        let source = ImageGenerationToolSource(viewModel: ChatViewModel())
        let result = try await source.resolve(
            toolName: "not_a_real_tool",
            arguments: "{}",
            session: ChatSession(title: "Test")
        )
        XCTAssertEqual(result.errorKind, .unknownTool)
    }

    func test_resolve_missingPrompt_stillReturnsInvalidArgumentsError() async throws {
        let source = ImageGenerationToolSource(viewModel: ChatViewModel())
        let result = try await source.resolve(
            toolName: "generate_image",
            arguments: "{}",
            session: ChatSession(title: "Test")
        )
        XCTAssertEqual(result.errorKind, .invalidArguments)
    }

    // MARK: - Configured but a genuine runtime failure: transient

    /// With a runtime installed but no active session, `generateImage` throws
    /// `.noActiveConversation` — a genuine runtime failure that must stay
    /// `.transient`, distinct from the not-configured `.permanent` above.
    func test_resolve_configuredButNoActiveConversation_returnsTransientError() async throws {
        let vm = makeConfiguredViewModel()
        XCTAssertNotNil(vm.imageRuntime, "Precondition: runtime IS configured, exercising the catch path, not the preflight")
        XCTAssertNil(vm.activeSessionID, "Precondition: no active session — generateImage() throws .noActiveConversation")

        let source = ImageGenerationToolSource(viewModel: vm)
        let result = try await source.resolve(
            toolName: "generate_image",
            arguments: #"{"prompt": "a lighthouse at dusk"}"#,
            session: ChatSession(title: "Test")
        )

        XCTAssertEqual(result.errorKind, .transient,
            "A genuine runtime failure (no active session) must remain .transient")
    }
}
