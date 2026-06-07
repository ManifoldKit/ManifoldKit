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
/// The cloud-API content is gated behind `#if Ollama || CloudSaaS`, but the
/// **type and `init()`** must remain public under disabled traits so the
/// migration call-site compiles for chat-only consumers (e.g. Fireside,
/// which builds without `Ollama`/`CloudSaaS`). The view body falls back to
/// `EmptyView()` when the traits are off.
///
/// This file is intentionally **not** wrapped in `#if Ollama || CloudSaaS`
/// — that's the whole point. It runs in the
/// `swift test --filter ManifoldUIModelManagementTests --disable-default-traits`
/// CI lane, which is exactly the configuration where Fireside lives.
///
/// ## Sabotage verification
///
/// To confirm the test actually catches a regression, restore whole-file
/// `#if Ollama || CloudSaaS` gating around `APIConfigurationView` (the
/// pre-fix layout) and re-run with default traits disabled. The build —
/// and therefore this test — must fail to compile, because
/// `APIConfigurationView` would no longer exist as a symbol. Restore the
/// always-public layout before committing. (Verified 2026-04-26.)
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
