import XCTest

/// API surface freeze test.
///
/// This test method does nothing at runtime. The real assertion is at
/// **compile time**: ``Fixtures/PublicSurfaceConsumer.swift`` references
/// every public BCK API we want to lock against accidental signature change.
/// If any consumed type is removed, renamed, or its signature drifts, the
/// fixture file fails to compile and this test target fails to build.
///
/// The static reference below is solely to keep the linker from
/// dead-code-eliminating the consumer body in optimised builds.
@MainActor
final class PublicSurfaceTests: XCTestCase {

    func test_publicSurfaceCompiles() {
        // Force the consumer body to be linked in. The function returns void
        // and is non-throwing — runtime side has nothing to verify.
        PublicSurfaceConsumer.consumeAllSurfaces()
        XCTAssertTrue(true, "Compilation is the assertion. See PublicSurfaceConsumer.swift.")
    }
}
