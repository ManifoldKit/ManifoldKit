@preconcurrency import XCTest
import Foundation
import SwiftUI
import ViewInspector
@testable import ManifoldUI
import ManifoldRuntime
@testable import ManifoldInference

/// Coverage for gap D of the UI-honesty audit (#2356): before this fix,
/// ``GenerativeContextMenuItems``' five generation actions (speech, image,
/// video, remix, animate) caught their errors with only `Log.ui.warning` —
/// unlike every other composer control, which calls
/// `viewModel.surfaceError`. A tapped action that failed left the user with
/// no visible feedback at all.
///
/// All five actions are driven into the same failure mode
/// (`ChatViewModel*Error.noActiveConversation` — the runtime IS configured,
/// which is what makes the button visible in the first place, but no
/// session is active) so this file exercises the one code path shared by
/// every catch block: does `viewModel.activeError` end up populated.
@MainActor
final class GenerativeContextMenuItemsTests: XCTestCase {

    // MARK: - Minimal fakes (mirrors VideoGenerationToolSourceTests)

    private final class StubVideoBackend: VideoGenerationBackend, @unchecked Sendable {
        func generate(prompt: String, config: VideoGenerationConfig) async throws -> AsyncThrowingStream<VideoGenerationEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func cancel() async {}
    }

    private final class StubMessageStore: MessageStore, @unchecked Sendable {
        func insertMessage(_ message: ChatMessage) async throws {}
        func updateMessage(_ message: ChatMessage) async throws {}
        func deleteMessage(_ messageID: UUID) async throws {}
        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] { [] }
        func deleteMessages(for sessionID: UUID) async throws {}
        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
    }

    /// A `ChatViewModel` with all three generation runtimes configured (so
    /// every `GenerativeContextMenuItems` button renders) but no active
    /// session — every generation call throws `.noActiveConversation`, which
    /// is what exercises each catch block.
    private func makeConfiguredViewModel() -> ChatViewModel {
        let vm = ChatViewModel()
        vm.configure(imageRuntime: ImageGenerationRuntime(
            service: ImageGenerationService(),
            messageStore: StubMessageStore()
        ))
        vm.configure(videoRuntime: VideoGenerationRuntime(
            service: VideoGenerationService(backend: StubVideoBackend()),
            messageStore: StubMessageStore()
        ))
        vm.configure(audioRuntime: AudioGenerationRuntime(
            service: AudioGenerationService(),
            messageStore: StubMessageStore()
        ))
        XCTAssertNil(vm.activeSessionID, "Precondition: no active session drives every action to .noActiveConversation")
        return vm
    }

    private func makeGeneratedImagePart(prompt: String) -> MessagePart {
        .generatedMedia(GeneratedMediaPayload(
            kind: .image,
            prompt: prompt,
            url: URL(fileURLWithPath: "/tmp/generated.png"),
            modelIdentifier: "test-model"
        ))
    }

    /// Polls `vm.activeError` until it's populated (the failure happens
    /// inside a `Task { }` spawned by the button's action closure) or a
    /// short deadline passes.
    private func waitForActiveError(_ vm: ChatViewModel) async {
        let deadline = Date().addingTimeInterval(2)
        while vm.activeError == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Generate Speech from This

    func test_generateSpeechButton_failure_surfacesError() async throws {
        let vm = makeConfiguredViewModel()
        let message = ChatMessage(role: .assistant, contentParts: [.text("Hello there")], sessionID: UUID())
        let view = GenerativeContextMenuItems(message: message, viewModel: vm)

        let button = try view.inspect().find(button: "Generate Speech from This")
        try button.tap()

        await waitForActiveError(vm)
        XCTAssertEqual(vm.activeError?.kind, .generation)
    }

    // MARK: - Generate Image from This

    func test_generateImageButton_failure_surfacesError() async throws {
        let vm = makeConfiguredViewModel()
        let message = ChatMessage(role: .assistant, contentParts: [.text("A lighthouse at dusk")], sessionID: UUID())
        let view = GenerativeContextMenuItems(message: message, viewModel: vm)

        let button = try view.inspect().find(button: "Generate Image from This")
        try button.tap()

        await waitForActiveError(vm)
        XCTAssertEqual(vm.activeError?.kind, .generation)
    }

    // MARK: - Generate Video from This

    func test_generateVideoButton_failure_surfacesError() async throws {
        let vm = makeConfiguredViewModel()
        let message = ChatMessage(role: .assistant, contentParts: [.text("A drone shot over the ocean")], sessionID: UUID())
        let view = GenerativeContextMenuItems(message: message, viewModel: vm)

        let button = try view.inspect().find(button: "Generate Video from This")
        try button.tap()

        await waitForActiveError(vm)
        XCTAssertEqual(vm.activeError?.kind, .generation)
    }

    // MARK: - Remix Image

    func test_remixImageButton_failure_surfacesError() async throws {
        let vm = makeConfiguredViewModel()
        let message = ChatMessage(
            role: .assistant,
            contentParts: [makeGeneratedImagePart(prompt: "a lighthouse")],
            sessionID: UUID()
        )
        let view = GenerativeContextMenuItems(message: message, viewModel: vm)

        let button = try view.inspect().find(button: "Remix Image")
        try button.tap()

        await waitForActiveError(vm)
        XCTAssertEqual(vm.activeError?.kind, .generation)
    }

    // MARK: - Animate as Video

    func test_animateAsVideoButton_failure_surfacesError() async throws {
        let vm = makeConfiguredViewModel()
        let message = ChatMessage(
            role: .assistant,
            contentParts: [makeGeneratedImagePart(prompt: "a lighthouse")],
            sessionID: UUID()
        )
        let view = GenerativeContextMenuItems(message: message, viewModel: vm)

        let button = try view.inspect().find(button: "Animate as Video")
        try button.tap()

        await waitForActiveError(vm)
        XCTAssertEqual(vm.activeError?.kind, .generation)
    }
}
