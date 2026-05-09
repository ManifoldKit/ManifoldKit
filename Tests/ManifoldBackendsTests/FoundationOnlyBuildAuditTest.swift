#if FoundationOnly
import XCTest
import ManifoldBackends

/// Build-time conformance for the `FoundationOnly` trait.
///
/// Compilation is the primary assertion: this file imports `ManifoldBackends`
/// while the heavy MLX/llama.cpp dependencies are absent from the resolved
/// graph, so a successful build of this test target proves
/// `ManifoldBackends` is wireable under FoundationOnly without those deps.
///
/// The runtime assertion is intentionally minimal — `FoundationBackend` and
/// the cloud-stub registrars must remain reachable. Any structural break
/// that drops `FoundationBackend` from the FoundationOnly compile set will
/// surface here.
///
/// Bundle-size / symbol-leak enforcement lives in
/// `scripts/check-foundation-only-bundle.sh`, exercised by the
/// `foundation-only-build` job in `.github/workflows/ci.yml`.
final class FoundationOnlyBuildAuditTest: XCTestCase {
    func testFoundationBackendStillWireable() {
        // FoundationBackend is annotated `@available(iOS 26, macOS 26, *)`
        // so we only consult the type metadata. Construction would force the
        // availability guard at runtime; we don't need that here.
        if #available(iOS 26, macOS 26, *) {
            // The metatype is the smallest reachable artifact; the
            // expression is the assertion.
            _ = FoundationBackend.self
        }
        // Cloud and Foundation registrar namespaces stay reachable. Their
        // bodies are no-ops under FoundationOnly (every cloud trait is off),
        // but the types must still resolve so consumer wiring code compiles.
        _ = CloudBackends.self
        _ = FoundationBackends.self
    }
}
#endif
