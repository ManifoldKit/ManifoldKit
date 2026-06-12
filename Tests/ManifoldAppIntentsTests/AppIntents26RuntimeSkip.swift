import XCTest

/// The AppIntents test fixtures are `@available(iOS 26, macOS 26, *)`, but
/// XCTest discovers and runs the annotated classes on older OSes anyway —
/// where the AppIntents runtime's parameter/entity introspection behaves
/// differently and the macOS-26 contract does not hold. These tests first
/// joined per-PR CI in v0.48 PR A3 (the AppIntents trait retirement);
/// CI runners are macos-15 (the n-1 floor), so the 26-only paths skip there.
func skipUnlessAppIntents26Runtime(file: StaticString = #filePath, line: UInt = #line) throws {
    guard #available(iOS 26, macOS 26, *) else {
        throw XCTSkip("Requires the iOS/macOS 26 AppIntents runtime (entity resolution / parameter metadata introspection)")
    }
}
