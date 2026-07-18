@preconcurrency import XCTest
import SwiftUI
import ViewInspector
import ManifoldInference
@testable import ManifoldUI

/// Unit tests for ``MessagePartsView/activeProgress(in:messageID:)`` — the
/// pure lookup backing the generated-media progress card's lifecycle
/// (`docs/UI-REFRESH-2026.md` §4A): progress → settled → missing.
///
/// Extracted as a static, `ChatViewModel`-free helper specifically so this
/// lifecycle is testable without standing up a live view-model/environment
/// (see the file's doc comment on `activeProgress` for why).
@MainActor
final class MessagePartsGenerationProgressTests: XCTestCase {

    private func imageProgress(
        messageID: UUID,
        step: Int = 1,
        totalSteps: Int = 10,
        isComplete: Bool = false
    ) -> ImageGenerationProgress {
        ImageGenerationProgress(
            messageID: messageID,
            prompt: "a lighthouse",
            step: step,
            totalSteps: totalSteps,
            isComplete: isComplete,
            error: nil
        )
    }

    // MARK: - Progress (in flight)

    func test_activeProgress_returnsEntry_whenIncomplete() {
        let id = UUID()
        let dict = [id: imageProgress(messageID: id, isComplete: false)]

        let result = MessagePartsView.activeProgress(in: dict, messageID: id)

        XCTAssertEqual(result?.messageID, id)
    }

    // MARK: - Settled (terminal — progress card stops rendering)

    func test_activeProgress_returnsNil_onceComplete() {
        let id = UUID()
        let dict = [id: imageProgress(messageID: id, isComplete: true)]

        XCTAssertNil(MessagePartsView.activeProgress(in: dict, messageID: id))
    }

    /// Cancellation and failure both settle through the same `isComplete`
    /// flag (see `ChatViewModel.handle(imageRuntimeEvent:)`), so the card
    /// disappears for either terminal outcome, not just success.
    func test_activeProgress_returnsNil_forCancelledOrFailedEntry() {
        let id = UUID()
        let cancelled = ImageGenerationProgress(
            messageID: id, prompt: "x", step: 3, totalSteps: 10, isComplete: true, error: nil
        )
        let failed = ImageGenerationProgress(
            messageID: id, prompt: "x", step: 3, totalSteps: 10, isComplete: true, error: "boom"
        )

        XCTAssertNil(MessagePartsView.activeProgress(in: [id: cancelled], messageID: id))
        XCTAssertNil(MessagePartsView.activeProgress(in: [id: failed], messageID: id))
    }

    // MARK: - Missing (no entry / no messageID to key on)

    func test_activeProgress_returnsNil_whenNoEntryForMessageID() {
        let dict: [UUID: ImageGenerationProgress] = [:]
        XCTAssertNil(MessagePartsView.activeProgress(in: dict, messageID: UUID()))
    }

    func test_activeProgress_returnsNil_whenMessageIDNil() {
        let id = UUID()
        let dict = [id: imageProgress(messageID: id, isComplete: false)]
        XCTAssertNil(MessagePartsView.activeProgress(in: dict, messageID: nil))
    }

    // MARK: - Video sibling shares the same generic helper

    func test_activeProgress_worksForVideoProgressToo() {
        let id = UUID()
        let inFlight = VideoGenerationProgress(
            messageID: id, prompt: "a drone shot", fractionComplete: 0.3, isComplete: false, error: nil
        )
        let settled = VideoGenerationProgress(
            messageID: id, prompt: "a drone shot", fractionComplete: 1.0, isComplete: true, error: nil
        )

        XCTAssertNotNil(MessagePartsView.activeProgress(in: [id: inFlight], messageID: id))
        XCTAssertNil(MessagePartsView.activeProgress(in: [id: settled], messageID: id))
    }

    // MARK: - Regression: environment-less render of a non-empty message

    /// Regression for a real crash this feature introduced and the review
    /// loop caught: `MessagePartsView` used to check generation progress
    /// unconditionally in `body`, which forced `@Environment(ChatViewModel.self)`
    /// to resolve even for a plain text-only message. That broke every
    /// environment-less caller — `MessageBubbleViewLogicTests` constructs
    /// `MessageBubbleView` (and transitively this view) with no
    /// `ChatViewModel` in scope, and a search that must exhaustively fail
    /// (`XCTAssertThrowsError(try view.inspect().find(...))`) forces full
    /// tree traversal, hitting the crash. Gating the progress check on
    /// `parts.isEmpty` fixed it; this test pins the fix by mirroring the
    /// exact failure shape: a non-empty message, no `ChatViewModel`
    /// environment, and an exhaustive "must not find" search.
    func test_nonEmptyMessage_rendersWithoutChatViewModelEnvironment() throws {
        let view = MessagePartsView(parts: [.text("Hello")], role: .assistant)

        // This must complete (throwing "not found" is fine and expected) —
        // it must NOT crash the process by touching an environment value
        // that was never injected.
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "nonexistent-identifier")
        )
    }
}
