import XCTest
@testable import ManifoldInference
import ManifoldHardware
import ManifoldTestSupport

/// Load-time chat-template integrity coverage (#1932), **live for single-file GGUF**
/// via record-on-first-observation into a per-file `ChatTemplateIntegritySidecar`.
///
/// The first load records the template digest; later loads compare against it.
/// A mismatch must **warn and proceed** — never throw, never gate, never alter
/// which template drives rendering. Tests drive through the coordinator with a
/// real sidecar file on disk to prove the mechanism is no longer inert.
@MainActor
final class ChatTemplateIntegrityTests: XCTestCase {

    // MARK: - Fixtures

    private var modelsDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatTemplateIntegrityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let modelsDir {
            // Restore writability first so a read-only-dir test can still be cleaned up.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: modelsDir.path)
            try? FileManager.default.removeItem(at: modelsDir)
        }
        modelsDir = nil
        try await super.tearDown()
    }

    private let templateA = "{% for m in messages %}{{ m.role }}: {{ m.content }}{% endfor %}"
    private let templateB = "{{ bos }}{% for m in messages %}<|{{ m.role }}|>{{ m.content }}{% endfor %}"

    private func modelURL(_ fileName: String = "model.gguf") -> URL {
        modelsDir.appendingPathComponent(fileName)
    }

    /// A single-file GGUF `ModelInfo` carrying `template`, located in `modelsDir`.
    private func makeModelInfo(template: String?, fileName: String = "model.gguf") -> ModelInfo {
        ModelInfo(
            name: "Test",
            fileName: fileName,
            url: modelURL(fileName),
            fileSize: 0,
            modelType: .gguf,
            chatTemplateRaw: template
        )
    }

    /// Writes a per-file integrity sidecar recording `hash` next to the model.
    private func writePerFileSidecar(recording hash: String, fileName: String = "model.gguf") throws {
        let url = ChatTemplateIntegritySidecar.sidecarURL(forModelAt: modelURL(fileName))
        let data = try JSONEncoder().encode(ChatTemplateIntegritySidecar(chatTemplateSHA256: hash))
        try data.write(to: url)
    }

    /// Decodes the recorded hash from the on-disk sidecar, or `nil` if absent.
    private func recordedSidecarHash(fileName: String = "model.gguf") -> String? {
        let url = ChatTemplateIntegritySidecar.sidecarURL(forModelAt: modelURL(fileName))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChatTemplateIntegritySidecar.self, from: data).chatTemplateSHA256
    }

    private func makeCoordinator() -> ModelLifecycleCoordinator {
        let coordinator = ModelLifecycleCoordinator()
        coordinator.registerBackendFactory { type in
            type == .gguf ? MockInferenceBackend() : nil
        }
        return coordinator
    }

    private func load(_ coordinator: ModelLifecycleCoordinator, _ model: ModelInfo) async throws {
        try await coordinator.loadModel(from: model, plan: ModelLoadPlan.systemManaged(requestedContextSize: 2048))
    }

    // MARK: - Integrity status (pure comparison)

    func test_integrityStatus_noSidecar_isNoRecordedHash() {
        XCTAssertEqual(makeCoordinator().chatTemplateIntegrityStatus(for: makeModelInfo(template: templateA)), .noRecordedHash)
    }

    func test_integrityStatus_matchingHash_isMatch() throws {
        let model = makeModelInfo(template: templateA)
        try writePerFileSidecar(recording: try XCTUnwrap(model.chatTemplateSHA256))

        XCTAssertEqual(makeCoordinator().chatTemplateIntegrityStatus(for: model), .match)
    }

    func test_integrityStatus_changedTemplate_isMismatch() throws {
        let model = makeModelInfo(template: templateA)
        let recorded = String(repeating: "0", count: 64) // cannot equal the live digest
        try writePerFileSidecar(recording: recorded)
        let coordinator = makeCoordinator()

        let current = try XCTUnwrap(model.chatTemplateSHA256)
        XCTAssertEqual(coordinator.chatTemplateIntegrityStatus(for: model), .mismatch(recorded: recorded, current: current))

        // Inline negative guard: a sidecar recording the *live* digest must NOT mismatch.
        try writePerFileSidecar(recording: current)
        if case .mismatch = coordinator.chatTemplateIntegrityStatus(for: model) {
            XCTFail("A matching recorded hash must not report a mismatch")
        }
    }

    // MARK: - Liveness (record-on-first-observation, through the coordinator)

    /// **First load, no sidecar:** the coordinator records a sidecar with the
    /// template's correct digest, and the pre-write status is silent (no warning).
    func test_firstLoad_writesSidecarWithCorrectHash_andIsSilent() async throws {
        let model = makeModelInfo(template: templateA)
        let coordinator = makeCoordinator()

        // No sidecar yet → nothing to compare → no warning.
        XCTAssertEqual(coordinator.chatTemplateIntegrityStatus(for: model), .noRecordedHash)
        XCTAssertNil(recordedSidecarHash(), "Precondition: no sidecar before first load")

        try await load(coordinator, model)

        XCTAssertTrue(coordinator.isModelLoaded)
        XCTAssertEqual(recordedSidecarHash(), model.chatTemplateSHA256,
                       "First load must record the live template digest into the sidecar")
    }

    /// **Second load, unchanged template (false-positive / consistency guard):**
    /// after the first load records the hash, loading the identical template again
    /// reports `.match` — the write and load digests hash the same source string,
    /// so an unchanged template must never warn.
    func test_secondLoad_unchangedTemplate_matchesNoFalsePositive() async throws {
        let model = makeModelInfo(template: templateA)

        try await load(makeCoordinator(), model) // records baseline

        let recorded = try XCTUnwrap(recordedSidecarHash())
        XCTAssertEqual(recorded, model.chatTemplateSHA256)

        let second = makeCoordinator()
        XCTAssertEqual(second.chatTemplateIntegrityStatus(for: model), .match,
                       "An unchanged template must report .match, not a spurious mismatch")
        try await load(second, model)
        XCTAssertTrue(second.isModelLoaded)
        XCTAssertEqual(recordedSidecarHash(), recorded, "Idempotent: a matching reload must not rewrite the sidecar")
    }

    /// **Second load, mutated template (the liveness proof):** after a baseline is
    /// recorded for templateA, loading templateB at the same path reports a
    /// `.mismatch` carrying both digests, the load still completes, and the
    /// recorded baseline is NOT silently re-written (drift keeps warning).
    func test_secondLoad_mutatedTemplate_warnsAndProceeds() async throws {
        let original = makeModelInfo(template: templateA)
        try await load(makeCoordinator(), original) // records hash(templateA)
        let hashA = try XCTUnwrap(recordedSidecarHash())

        // The GGUF on disk is swapped: same path, different embedded template.
        let mutated = makeModelInfo(template: templateB)
        let hashB = try XCTUnwrap(mutated.chatTemplateSHA256)
        XCTAssertNotEqual(hashA, hashB, "Fixture sanity: the two templates must hash differently")

        let coordinator = makeCoordinator()

        // The exact liveness assertion: the recorded baseline (hashA) is compared
        // against the freshly-loaded template (hashB) and reported as a mismatch.
        XCTAssertEqual(coordinator.chatTemplateIntegrityStatus(for: mutated),
                       .mismatch(recorded: hashA, current: hashB),
                       "A swapped template must surface as a mismatch carrying both digests")

        try await load(coordinator, mutated)

        XCTAssertTrue(coordinator.isModelLoaded, "A template mismatch must warn, not block the load")
        XCTAssertEqual(coordinator.selectedChatTemplateRaw, templateB,
                       "The freshly-loaded template must still drive rendering after a mismatch")
        XCTAssertEqual(recordedSidecarHash(), hashA,
                       "Idempotent: a mismatch must not re-baseline the sidecar (drift keeps warning)")
    }

    /// **Best-effort write:** if the sidecar cannot be written (read-only models
    /// directory), the load still completes without crashing or throwing.
    func test_firstLoad_readOnlyDir_proceedsWithoutCrash() async throws {
        let model = makeModelInfo(template: templateA)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: modelsDir.path)

        let coordinator = makeCoordinator()
        try await load(coordinator, model)

        XCTAssertTrue(coordinator.isModelLoaded, "A sidecar write failure must not block the load")
        // Restore writability so the assertion and teardown can read/clean the dir.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: modelsDir.path)
        XCTAssertNil(recordedSidecarHash(), "No sidecar should exist when the write failed")
    }

    // MARK: - #1909 anti-regression

    /// The integrity check must not perturb what drives rendering:
    /// `selectedChatTemplateRaw` must be byte-identical whether the recorded hash
    /// matches, mismatches, or is absent.
    func test_load_integrityCheck_doesNotAlterRenderedTemplate() async throws {
        let model = makeModelInfo(template: templateA)
        let liveHash = try XCTUnwrap(model.chatTemplateSHA256)

        // 1. Matching baseline already on disk.
        try writePerFileSidecar(recording: liveHash)
        let matching = makeCoordinator()
        try await load(matching, model)

        // 2. Mismatching baseline.
        try writePerFileSidecar(recording: String(repeating: "f", count: 64))
        let mismatching = makeCoordinator()
        try await load(mismatching, model)

        // 3. No baseline at all.
        try FileManager.default.removeItem(at: ChatTemplateIntegritySidecar.sidecarURL(forModelAt: modelURL()))
        let absent = makeCoordinator()
        try await load(absent, model)

        XCTAssertEqual(matching.selectedChatTemplateRaw, templateA)
        XCTAssertEqual(mismatching.selectedChatTemplateRaw, matching.selectedChatTemplateRaw,
                       "A hash mismatch must leave the render-driving template identical to the match case")
        XCTAssertEqual(absent.selectedChatTemplateRaw, matching.selectedChatTemplateRaw,
                       "Absence of a recorded hash must leave the render-driving template identical")
    }
}
