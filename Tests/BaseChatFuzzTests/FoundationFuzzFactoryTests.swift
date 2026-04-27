#if canImport(FoundationModels)
import XCTest
import BaseChatBackends
import BaseChatFuzz
import BaseChatFuzzBackends

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

    func test_makeHandle_throwsWhenAppleIntelligenceUnavailable() async {
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
