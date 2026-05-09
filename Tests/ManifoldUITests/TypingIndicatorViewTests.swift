@preconcurrency import XCTest
import SwiftUI
@testable import ManifoldUI

@MainActor
final class TypingIndicatorViewTests: XCTestCase {

    func testTypingIndicatorViewRenders() {
        let view = TypingIndicatorView()
        // Materialize body to verify no runtime crash during rendering.
        _ = view.body
    }

    func testStreamingCursorViewRenders() {
        let view = StreamingCursorView()
        _ = view.body
    }

    func testModelLoadingIndicatorViewInitializesWithoutProgress() {
        let view = ModelLoadingIndicatorView()
        XCTAssertNil(view.progress)
    }

    func testModelLoadingIndicatorViewInitializesWithProgress() {
        let view = ModelLoadingIndicatorView(progress: 0.75)
        XCTAssertEqual(view.progress, 0.75)
    }
}
