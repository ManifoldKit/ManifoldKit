import XCTest
import SwiftUI
@testable import ManifoldUIModelManagement

/// Regression test for PR #796 review feedback.
///
/// `APIConfigurationView` is the canonical thing host apps wire into
/// `ChatView`'s new `apiConfiguration:` view-builder slot:
///
/// ```swift
/// ChatView(
///     showModelManagement: $showSheet,
///     apiConfiguration: { APIConfigurationView() }
/// )
/// ```
///
/// The **type and `init()`** must remain public in every build shape so the
/// migration call-site compiles for chat-only consumers (e.g. Fireside).
/// Historically the view body was gated behind the Ollama / CloudSaaS
/// traits; those retired in v0.48 (PR A4) and the view now compiles whole
/// in every configuration — this guard keeps the symbol public under
/// `--disable-default-traits`, the lane where Fireside lives.
final class APIConfigurationViewMigrationGuardTests: XCTestCase {

    @MainActor
    func test_apiConfigurationView_isInstantiableUnderDisabledTraits() {
        // The cast to `AnyView` exercises both the public initializer and
        // the `View` conformance, which is what host-app code relies on.
        let view: AnyView = AnyView(APIConfigurationView())
        _ = view
        // Compilation is the assertion (API-surface guard).
    }

    func test_apiConfigurationView_typeIsPublic() {
        // Pin the type's existence at the module surface. Even if the body
        // collapses to `EmptyView` under disabled traits, the type itself
        // must remain externally referenceable.
        let typeName = String(describing: APIConfigurationView.self)
        XCTAssertEqual(typeName, "APIConfigurationView")
    }
}
