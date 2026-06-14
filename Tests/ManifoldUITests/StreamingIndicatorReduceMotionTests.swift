import XCTest
@testable import ManifoldUI

/// Covers the Reduce Motion gating of the shared streaming indicators (#1833).
/// SwiftUI animation can't be inspected directly under XCTest, so each view
/// exposes the reduce-motion-dependent appearance decision as a pure static
/// helper; these tests assert the static fallback is genuinely static (no
/// per-element variation that would imply movement) while the animated path
/// still varies.
final class StreamingIndicatorReduceMotionTests: XCTestCase {

    // MARK: - TypingIndicatorView

    func test_typingDots_areUniform_whenReduceMotionOn() {
        let active = TypingIndicatorView.dotAppearance(reduceMotion: true, isActive: true)
        let inactive = TypingIndicatorView.dotAppearance(reduceMotion: true, isActive: false)
        // Active and inactive dots must be identical — a static three-dot glyph
        // with no scale/opacity pulse.
        XCTAssertEqual(active.scale, inactive.scale)
        XCTAssertEqual(active.opacity, inactive.opacity)
        XCTAssertEqual(active.scale, 1.0)
    }

    func test_typingDots_varyByActiveState_whenReduceMotionOff() {
        let active = TypingIndicatorView.dotAppearance(reduceMotion: false, isActive: true)
        let inactive = TypingIndicatorView.dotAppearance(reduceMotion: false, isActive: false)
        XCTAssertNotEqual(active.scale, inactive.scale)
        XCTAssertGreaterThan(active.scale, inactive.scale)
        XCTAssertGreaterThan(active.opacity, inactive.opacity)
    }

    // MARK: - StreamingCursorView

    func test_cursor_staysSolid_whenReduceMotionOn() {
        // Opacity is independent of the pulsing `isVisible` toggle.
        XCTAssertEqual(StreamingCursorView.cursorOpacity(reduceMotion: true, isVisible: true), 1.0)
        XCTAssertEqual(StreamingCursorView.cursorOpacity(reduceMotion: true, isVisible: false), 1.0)
    }

    func test_cursor_pulses_whenReduceMotionOff() {
        XCTAssertEqual(StreamingCursorView.cursorOpacity(reduceMotion: false, isVisible: true), 1.0)
        XCTAssertEqual(StreamingCursorView.cursorOpacity(reduceMotion: false, isVisible: false), 0.0)
    }
}
