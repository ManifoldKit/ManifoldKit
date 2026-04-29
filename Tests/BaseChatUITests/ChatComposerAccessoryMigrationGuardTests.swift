import XCTest
import SwiftUI
@testable import BaseChatUI

/// Regression test for the composer-accessory seam introduced for optional UI
/// modules such as BaseChatVoice.
///
/// The test target builds without the `Voice` trait; that's intentional. The
/// seam must remain available even when optional modules are absent so host apps
/// can keep composing accessory views from sibling packages without creating a
/// dependency cycle back into `BaseChatUI`.
final class ChatComposerAccessoryMigrationGuardTests: XCTestCase {

    @MainActor
    func test_chatView_isInstantiableWithComposerAccessoryUnderDisabledTraits() {
        let view: AnyView = AnyView(
            ChatView(
                showModelManagement: .constant(false),
                composerAccessory: { Text("Voice spike") },
                apiConfiguration: { EmptyView() }
            )
        )

        XCTAssertNotNil(view)
    }
}
