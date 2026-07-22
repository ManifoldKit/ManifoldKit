@preconcurrency import XCTest
import Foundation
@testable import ManifoldUI
import ManifoldRuntime
@testable import ManifoldInference

/// Coverage for the ``ImageGenerationToolSource`` not-configured alignment
/// (#2128 item E): before this fix the image source folded not-configured
/// into the same blanket `.transient` catch as genuine runtime failures, so
/// the model was told the failure was retryable when no image backend was
/// wired at all. Mirrors the #2356 `VideoGenerationToolSource` fix — a
/// truthful `.permanent` for not-configured, `.transient` reserved for real
/// runtime failures.
@MainActor
final class ImageGenerationToolSourceTests: XCTestCase {

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
