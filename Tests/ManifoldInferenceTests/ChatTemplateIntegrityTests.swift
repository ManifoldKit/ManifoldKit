import XCTest
@testable import ManifoldInference
import ManifoldHardware
import ManifoldTestSupport

/// Load-time chat-template integrity coverage (Piece 1 of #1932).
///
/// A mismatch between a model's freshly-loaded chat template and the digest
/// recorded in its `.manifoldkit-package.json` sidecar must **warn and proceed**
/// — never throw, never gate, never alter which template drives rendering.
@MainActor
final class ChatTemplateIntegrityTests: XCTestCase {

    // MARK: - Fixtures

    private var packageDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        packageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatTemplateIntegrityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let packageDir { try? FileManager.default.removeItem(at: packageDir) }
        packageDir = nil
        try await super.tearDown()
    }

    private let template = "{% for m in messages %}{{ m.role }}: {{ m.content }}{% endfor %}"

    /// Builds a `ModelInfo` whose `url` lives inside `packageDir`, carrying the
    /// shared chat template.
    private func makeModelInfo() -> ModelInfo {
        ModelInfo(
            name: "Test",
            fileName: "model.gguf",
            url: packageDir.appendingPathComponent("model.gguf"),
            fileSize: 0,
            modelType: .gguf,
            chatTemplateRaw: template
        )
    }

    /// Writes a sidecar manifest next to the model recording `hash`.
    private func writeSidecar(recording hash: String?) throws {
        let manifest = DownloadedModelPackageManifest(
            packageKind: .mlxSnapshot,
            id: "org/model",
            displayName: "Test",
            files: ["model.gguf"],
            chatTemplateSHA256: hash
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: packageDir.appendingPathComponent(DownloadedModelPackageManifest.fileName))
    }

    private func makeCoordinator() -> ModelLifecycleCoordinator {
        let coordinator = ModelLifecycleCoordinator()
        coordinator.registerBackendFactory { type in
            type == .gguf ? MockInferenceBackend() : nil
        }
        return coordinator
    }

    // MARK: - Integrity status (pure comparison)

    func test_integrityStatus_noSidecar_isNoRecordedHash() {
        let coordinator = makeCoordinator()

        XCTAssertEqual(coordinator.chatTemplateIntegrityStatus(for: makeModelInfo()), .noRecordedHash)
    }

    func test_integrityStatus_matchingHash_isMatch() throws {
        let model = makeModelInfo()
        try writeSidecar(recording: model.chatTemplateSHA256)
        let coordinator = makeCoordinator()

        XCTAssertEqual(coordinator.chatTemplateIntegrityStatus(for: model), .match)
    }

    func test_integrityStatus_changedTemplate_isMismatch() throws {
        let model = makeModelInfo()
        let recorded = String(repeating: "0", count: 64) // a hash that cannot equal the live digest
        try writeSidecar(recording: recorded)
        let coordinator = makeCoordinator()

        let current = try XCTUnwrap(model.chatTemplateSHA256)
        XCTAssertEqual(
            coordinator.chatTemplateIntegrityStatus(for: model),
            .mismatch(recorded: recorded, current: current)
        )
        // Sabotage check (verifies the assertion above is load-bearing): a sidecar
        // recording the *live* digest must NOT report a mismatch.
        try writeSidecar(recording: current)
        if case .mismatch = coordinator.chatTemplateIntegrityStatus(for: model) {
            XCTFail("A matching recorded hash must not report a mismatch")
        }
    }

    // MARK: - Load path

    /// A recorded-hash mismatch warns but the load still proceeds (no throw),
    /// and the embedded template still reaches the renderer unchanged.
    func test_load_withMismatchedHash_proceedsAndKeepsTemplate() async throws {
        try writeSidecar(recording: String(repeating: "a", count: 64))
        let coordinator = makeCoordinator()

        try await coordinator.loadModel(
            from: makeModelInfo(),
            plan: ModelLoadPlan.systemManaged(requestedContextSize: 2048)
        )

        XCTAssertTrue(coordinator.isModelLoaded, "A template mismatch must warn, not block the load")
        XCTAssertEqual(coordinator.selectedChatTemplateRaw, template,
                       "The loaded model's embedded template must still drive rendering after a mismatch")
    }

    /// **Anti-regression guard (#1909):** the integrity check must not perturb
    /// what drives rendering. `selectedChatTemplateRaw` must be byte-identical
    /// whether the recorded hash matches, mismatches, or is absent entirely.
    func test_load_integrityCheck_doesNotAlterRenderedTemplate() async throws {
        let model = makeModelInfo()

        // 1. Matching sidecar.
        try writeSidecar(recording: model.chatTemplateSHA256)
        let matching = makeCoordinator()
        try await matching.loadModel(from: model, plan: ModelLoadPlan.systemManaged(requestedContextSize: 2048))

        // 2. Mismatching sidecar.
        try writeSidecar(recording: String(repeating: "f", count: 64))
        let mismatching = makeCoordinator()
        try await mismatching.loadModel(from: model, plan: ModelLoadPlan.systemManaged(requestedContextSize: 2048))

        // 3. No sidecar at all.
        try FileManager.default.removeItem(at: packageDir.appendingPathComponent(DownloadedModelPackageManifest.fileName))
        let absent = makeCoordinator()
        try await absent.loadModel(from: model, plan: ModelLoadPlan.systemManaged(requestedContextSize: 2048))

        XCTAssertEqual(matching.selectedChatTemplateRaw, template)
        XCTAssertEqual(mismatching.selectedChatTemplateRaw, matching.selectedChatTemplateRaw,
                       "A hash mismatch must leave the render-driving template identical to the match case")
        XCTAssertEqual(absent.selectedChatTemplateRaw, matching.selectedChatTemplateRaw,
                       "Absence of a recorded hash must leave the render-driving template identical")
    }
}
