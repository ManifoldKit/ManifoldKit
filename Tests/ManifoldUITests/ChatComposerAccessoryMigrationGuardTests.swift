import XCTest
import SwiftUI
@testable import ManifoldUI

/// Regression test for the composer-accessory seam introduced for optional UI
/// modules such as ManifoldVoice.
///
/// The test target builds without the `Voice` trait; that's intentional. The
/// seam must remain available even when optional modules are absent so host apps
/// can keep composing accessory views from sibling packages without creating a
/// dependency cycle back into `ManifoldUI`.
final class ChatComposerAccessoryMigrationGuardTests: XCTestCase {

    @MainActor
    func test_chatView_isInstantiableWithoutAPIConfigurationView() {
        let view: AnyView = AnyView(
            ChatView(showModelManagement: .constant(false))
        )
        _ = view
        // Compilation is the assertion (API-surface guard).
    }

    @MainActor
    func test_chatView_isInstantiableWithComposerAccessoryUnderDisabledTraits() {
        let view: AnyView = AnyView(
            ChatView(showModelManagement: .constant(false))
                .chatComposerAccessory { Text("Voice spike") }
        )
        _ = view
        // Compilation is the assertion (API-surface guard).
    }
}
