#if canImport(FoundationModels)
import XCTest
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldCloudCore
import ManifoldFuzz
import ManifoldFuzzBackends

@available(macOS 26, iOS 26, *)
final class FoundationFuzzFactoryTests: XCTestCase {

    struct DefaultsOnlyFactory: FuzzBackendFactory {
        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            fatalError("not used; only inspected for protocol-extension defaults")
        }
    }

    func test_supportsDeterministicReplay_isTrue() {
        XCTAssertTrue(
            FoundationFuzzFactory().supportsDeterministicReplay,
            "FoundationFuzzFactory must report deterministic replay so Apple Intelligence findings are replayable"
        )
    }

    func test_protocolDefault_supportsDeterministicReplay_isTrue() {
        XCTAssertTrue(
            DefaultsOnlyFactory().supportsDeterministicReplay,
            "FuzzBackendFactory protocol default must remain `true` — local backends rely on it"
        )
    }

    /// `XCTest` discovers test methods via the ObjC runtime, bypassing Swift's
    /// `@available` check — the class-level `@available(macOS 26, iOS 26, *)`
    /// above only gates compile-time API availability, it does not stop these
    /// methods from *running* on a host whose OS predates 26. Evaluating
    /// `FoundationBackend.isAvailable` (→ `SystemLanguageModel.default
    /// .availability`) on such a host doesn't return `false` — it crashed CI
    /// with signal 11 (ManifoldKit#2367 review): CI's `macos-15` runner has
    /// the SDK 26 toolchain but not the OS-26 runtime FoundationModels needs
    /// (the documented #2096 gap), and no GitHub-hosted macOS 26 runner
    /// exists yet. `FoundationBackendUnitTests.setUp()` in
    /// `ManifoldBackendsTests` already guards this exact call with the same
    /// `ProcessInfo` check — this suite predates that suite ever running in
    /// the same CI batch (#2367 wired it in for the first time) and never
    /// picked up the pattern. Applied per-method rather than via `setUp()`
    /// so the two tests above, which never touch FoundationModels, keep
    /// running on every CI host instead of skipping needlessly.
    private func skipUnlessRealFoundationModelsOS() throws {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ) else {
            throw XCTSkip("FoundationModels requires iOS 26 / macOS 26 actually running, not just the SDK (#2096) — evaluating FoundationBackend.isAvailable on an older OS is unsafe, not merely `false`")
        }
    }

    func test_makeHandle_throwsWhenAppleIntelligenceUnavailable() async throws {
        try skipUnlessRealFoundationModelsOS()
        guard !FoundationBackend.isAvailable else { return }
        do {
            _ = try await FoundationFuzzFactory().makeHandle()
            XCTFail("makeHandle() must throw when Apple Intelligence is unavailable")
        } catch let error as FuzzBackendFactoryError {
            XCTAssertTrue(
                error.description.contains("Apple Intelligence is not available"),
                "unexpected error: \(error)"
            )
        } catch {
            XCTFail("expected FuzzBackendFactoryError, got \(type(of: error)): \(error)")
        }
    }

    func test_makeHandle_returnsLoadedBackend() async throws {
        try skipUnlessRealFoundationModelsOS()
        try XCTSkipUnless(
            FoundationBackend.isAvailable,
            "Apple Intelligence is unavailable on this host — enable it in Settings > Apple Intelligence & Siri to exercise the Foundation fuzz factory."
        )
        let handle = try await FoundationFuzzFactory().makeHandle()
        XCTAssertTrue(
            handle.backend.isModelLoaded,
            "factory must pre-load the backend so the runner's first generate() call does not throw"
        )
        XCTAssertEqual(handle.backendName, "foundation")
        XCTAssertEqual(handle.modelId, "apple-intelligence")
        XCTAssertNil(
            handle.templateMarkers,
            "Foundation has no chat-template markers — Apple's SDK exposes no thinking/reasoning surface"
        )
    }
}
#endif
