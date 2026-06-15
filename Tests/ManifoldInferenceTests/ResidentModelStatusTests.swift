import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for ``ResidentModelStatus`` and ``InferenceService/queuedRequestCount``.
///
/// Uses XCTestCase (not Swift Testing) per the two-runner constraint (#681):
/// mixing Swift Testing and XCTest in one process causes libmalloc SIGABRT.
@MainActor
final class ResidentModelStatusTests: XCTestCase {

    // MARK: - Helpers

    private func makeService(modelName: String = "TestModel") -> (InferenceService, MockInferenceBackend) {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["hello"]
        let service = InferenceService(backend: backend, name: "Mock", modelName: modelName)
        return (service, backend)
    }

    // MARK: - residentModelStatus — loaded

    func test_residentModelStatus_nonNil_whenModelLoaded() {
        let (service, _) = makeService(modelName: "Llama-3")
        XCTAssertNotNil(service.residentModelStatus,
                        "residentModelStatus must be non-nil when a model is loaded")
    }

    func test_residentModelStatus_modelID_matchesModelName() {
        let (service, _) = makeService(modelName: "Llama-3")
        XCTAssertEqual(service.residentModelStatus?.modelID, "Llama-3",
                       "modelID must match the name supplied at load time")
    }

    func test_residentModelStatus_backend_matchesBackendName() {
        let (service, _) = makeService()
        XCTAssertEqual(service.residentModelStatus?.backend, "Mock",
                       "backend must match the name supplied at load time")
    }

    func test_residentModelStatus_loadedAt_isRecent() {
        let before = Date()
        let (service, _) = makeService()
        let after = Date()
        guard let loadedAt = service.residentModelStatus?.loadedAt else {
            XCTFail("loadedAt must be non-nil when a model is loaded")
            return
        }
        XCTAssertGreaterThanOrEqual(loadedAt, before,
                                    "loadedAt must not precede service creation")
        XCTAssertLessThanOrEqual(loadedAt, after,
                                 "loadedAt must not be in the future")
    }

    func test_residentModelStatus_estimatedFootprintBytes_nilForDebugInit() {
        // The #if DEBUG init path (used by InferenceService(backend:name:)) does
        // not have access to a ModelLoadPlan so footprint is always nil there.
        let (service, _) = makeService()
        XCTAssertNil(service.residentModelStatus?.estimatedFootprintBytes,
                     "estimatedFootprintBytes must be nil when loaded via the debug-init path (no plan)")
    }

    // MARK: - residentModelStatus — unloaded

    func test_residentModelStatus_nil_whenNoModelLoaded() {
        let service = InferenceService()
        XCTAssertNil(service.residentModelStatus,
                     "residentModelStatus must be nil when no model is loaded")
    }

    func test_residentModelStatus_nil_afterUnload() {
        let (service, _) = makeService()
        XCTAssertNotNil(service.residentModelStatus, "pre-condition: should be loaded")
        service.unloadModel()
        XCTAssertNil(service.residentModelStatus,
                     "residentModelStatus must be nil after unloadModel()")
    }

    // MARK: - queuedRequestCount

    func test_queuedRequestCount_zeroInitially() {
        let (service, _) = makeService()
        XCTAssertEqual(service.queuedRequestCount, 0,
                       "queuedRequestCount must be 0 before any requests are enqueued")
    }

    func test_queuedRequestCount_zeroAfterGenerationCompletes() async throws {
        let (service, _) = makeService()
        let (_, stream) = try service.enqueue(
            messages: [Message.user("hi")]
        )
        // Drain the stream to let the queue settle.
        for try await _ in stream.events {}
        XCTAssertEqual(service.queuedRequestCount, 0,
                       "queuedRequestCount must return to 0 after a generation finishes")
    }

    // MARK: - lastActivityAt

    func test_lastActivityAt_updatedAfterGenerationCompletes() async throws {
        let (service, _) = makeService()
        let before = Date()
        let (_, stream) = try service.enqueue(
            messages: [Message.user("hi")]
        )
        for try await _ in stream.events {}
        let after = Date()
        guard let status = service.residentModelStatus else {
            XCTFail("residentModelStatus must be non-nil after generation")
            return
        }
        XCTAssertGreaterThanOrEqual(status.lastActivityAt, before,
                                    "lastActivityAt must be >= the moment before enqueue")
        XCTAssertLessThanOrEqual(status.lastActivityAt, after,
                                 "lastActivityAt must not be in the future")
    }

    func test_idleDuration_isNonNegative() async throws {
        let (service, _) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")])
        for try await _ in stream.events {}
        let status = service.residentModelStatus
        XCTAssertNotNil(status)
        XCTAssertGreaterThanOrEqual(status?.idleDuration ?? -1, 0,
                                    "idleDuration must always be >= 0")
    }
}
