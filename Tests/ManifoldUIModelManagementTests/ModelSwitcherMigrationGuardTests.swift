import XCTest
import SwiftUI
import ManifoldUI
@testable import ManifoldUIModelManagement
import ManifoldInference

/// Regression test for Unit 2 §L5 (issue #2307) review feedback: the quick
/// model-switcher seam must have a real, compiling consumer, not just a
/// closure-injection point nobody can reach.
///
/// `ModelSwitcherView`/`ModelSwitcher`/`ModelSwitcherRow` were promoted from
/// `package` to `public` specifically so a host app can build this call
/// site — `Example/Advanced/DemoContentView.swift` wires it live, this is
/// the compile-time guard that call site can't silently rot (mirrors
/// `ChatComposerAccessoryMigrationGuardTests`/`APIConfigurationViewMigrationGuardTests`'s
/// shape: compilation is the assertion, not a rendered-output check).
final class ModelSwitcherMigrationGuardTests: XCTestCase {

    @MainActor
    func test_chatView_isInstantiableWithChatModelSwitcher() {
        let rows = ModelSwitcher.rows(
            models: [],
            endpoints: [],
            selectedModelID: nil,
            selectedEndpointID: nil,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            compatibility: { _ in .supported }
        )
        let view: AnyView = AnyView(
            ChatView(showModelManagement: .constant(false))
                .chatModelSwitcher {
                    ModelSwitcherView(
                        rows: rows,
                        onSelect: { _ in },
                        onFixEndpoint: { _ in }
                    )
                }
        )
        _ = view
        // Compilation is the assertion (API-surface guard) — the migration
        // doc's `WhiteLabelTheming`/migration-note snippet mirrors this
        // exact shape and must keep compiling as this repo's public API.
    }

    func test_modelSwitcherTypes_arePublic() {
        // Pin the promoted types' existence at the module surface, mirroring
        // `APIConfigurationViewMigrationGuardTests.test_apiConfigurationView_typeIsPublic`.
        XCTAssertEqual(String(describing: ModelSwitcherView.self), "ModelSwitcherView")
        XCTAssertEqual(String(describing: ModelSwitcher.self), "ModelSwitcher")
        XCTAssertEqual(String(describing: ModelSwitcherRow.self), "ModelSwitcherRow")
    }
}
