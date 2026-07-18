import XCTest
import SwiftUI
import ViewInspector
@testable import ManifoldUI

/// Covers the Unit 2 §L1 scroll-to-bottom control added to `ChatHistoryView`:
/// the pure visibility/appearance decisions (unit-testable without a live
/// `ScrollView`) plus its VoiceOver contract.
final class ScrollToBottomControlTests: XCTestCase {

    // MARK: - ChatHistoryScrollBehavior.isScrolledAwayFromBottom

    func test_isScrolledAwayFromBottom_falseAtRest() {
        // Content exactly fills the container, offset at 0 — resting at the
        // bottom anchor, as `.defaultScrollAnchor(.bottom)` leaves it.
        XCTAssertFalse(
            ChatHistoryScrollBehavior.isScrolledAwayFromBottom(
                offsetY: 0,
                contentHeight: 600,
                containerHeight: 600
            )
        )
    }

    func test_isScrolledAwayFromBottom_falseWithinThreshold() {
        // 40pt short of the bottom edge — inside the 80pt threshold.
        XCTAssertFalse(
            ChatHistoryScrollBehavior.isScrolledAwayFromBottom(
                offsetY: 560,
                contentHeight: 1000,
                containerHeight: 400
            )
        )
    }

    func test_isScrolledAwayFromBottom_trueBeyondThreshold() {
        // 200pt short of the bottom edge — well past the 80pt threshold.
        XCTAssertTrue(
            ChatHistoryScrollBehavior.isScrolledAwayFromBottom(
                offsetY: 400,
                contentHeight: 1000,
                containerHeight: 400
            )
        )
    }

    func test_isScrolledAwayFromBottom_respectsCustomThreshold() {
        XCTAssertFalse(
            ChatHistoryScrollBehavior.isScrolledAwayFromBottom(
                offsetY: 400,
                contentHeight: 1000,
                containerHeight: 400,
                threshold: 500
            )
        )
    }

    // MARK: - ScrollToBottomButton.appearanceAnimation (Reduce Motion)

    func test_appearanceAnimation_nil_whenReduceMotionOn() {
        XCTAssertNil(ScrollToBottomButton.appearanceAnimation(reduceMotion: true))
    }

    func test_appearanceAnimation_nonNil_whenReduceMotionOff() {
        XCTAssertNotNil(ScrollToBottomButton.appearanceAnimation(reduceMotion: false))
    }

    // MARK: - Accessibility contract

    @MainActor
    func test_scrollToBottomButton_exposesVoiceOverLabel() throws {
        let view = ScrollToBottomButton(reduceMotion: false, action: {})

        let label = try view.inspect().find(ViewType.Button.self).accessibilityLabel().string()
        XCTAssertEqual(label, "Scroll to latest message")
    }

    @MainActor
    func test_scrollToBottomButton_invokesActionOnTap() throws {
        var didTap = false
        let view = ScrollToBottomButton(reduceMotion: false, action: { didTap = true })

        try view.inspect().find(ViewType.Button.self).tap()

        XCTAssertTrue(didTap)
    }
}
