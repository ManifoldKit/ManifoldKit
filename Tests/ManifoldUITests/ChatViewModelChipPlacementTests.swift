import XCTest
import SwiftUI
@testable import ManifoldUI

/// Unit coverage for `ChatView.showsModelChipInToolbar(horizontalSizeClass:)`
/// — the dispatch that keeps the model-switcher chip reachable on compact
/// width (#2307). End-to-end reachability is covered by
/// `ModelSwitcherChipUITests` (example-ui-smoke); this suite is the CI gate.
@MainActor
final class ChatViewModelChipPlacementTests: XCTestCase {

    func test_showsModelChipInToolbar_compact_isFalseOnIOS() {
        #if os(iOS)
        XCTAssertFalse(
            ChatView<EmptyView>.showsModelChipInToolbar(horizontalSizeClass: .compact),
            "Compact width must use the safeAreaInset content-chrome band, not the toolbar"
        )
        #else
        XCTAssertTrue(
            ChatView<EmptyView>.showsModelChipInToolbar(horizontalSizeClass: .compact),
            "macOS has no compact size class failure mode — always toolbar"
        )
        #endif
    }

    func test_showsModelChipInToolbar_regular_isTrue() {
        XCTAssertTrue(
            ChatView<EmptyView>.showsModelChipInToolbar(horizontalSizeClass: .regular),
            "Regular width keeps the chip at .principal in the toolbar"
        )
    }

    func test_showsModelChipInToolbar_nil_isTrue() {
        // nil size class (e.g. early layout pass / macOS) must not hide the chip.
        XCTAssertTrue(
            ChatView<EmptyView>.showsModelChipInToolbar(horizontalSizeClass: nil),
            "nil horizontalSizeClass must not drop the chip into the inset band"
        )
    }
}
