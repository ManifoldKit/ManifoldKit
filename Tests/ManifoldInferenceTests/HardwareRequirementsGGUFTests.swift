import XCTest
@testable import ManifoldTestSupport

final class HardwareRequirementsGGUFTests: XCTestCase {

    private var tempDirectory: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        tempDirectory = repoRoot
            .appendingPathComponent(".build/test-temp/HardwareRequirementsGGUFTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    func test_findGGUFModel_prefersEnvOverride() {
        let alpha = createGGUFFile("alpha-model.gguf")
        _ = createGGUFFile("beta-model.gguf")

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            environment: ["LLAMA_TEST_MODEL": "alpha"],
            minimumModelSize: 1
        )

        XCTAssertEqual(result?.standardizedFileURL.path, alpha.standardizedFileURL.path)
    }

    func test_findGGUFModel_searchesOneNestedDirectoryLevel() {
        let nested = createGGUFFile("qwen/qwen3-thinking.gguf")

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            nameContains: "thinking",
            minimumModelSize: 1
        )

        XCTAssertEqual(result?.standardizedFileURL.path, nested.standardizedFileURL.path)
    }

    func test_findGGUFModel_searchesFamilyNameGroupedLayout() {
        // Models/<family>/<name>/<file>.gguf — depth 3 under the search root.
        // Pre-#2384 discovery stopped at depth 2 and silently skipped these.
        let grouped = createGGUFFile("gguf/Qwen3-VL-8B/model.gguf")

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            nameContains: "Qwen3-VL",
            minimumModelSize: 1
        )

        XCTAssertEqual(result?.standardizedFileURL.path, grouped.standardizedFileURL.path)
    }

    func test_findGGUFModel_flatLayoutStillWorks() {
        let flat = createGGUFFile("tiny-flat.gguf")

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            nameContains: "tiny-flat",
            minimumModelSize: 1
        )

        XCTAssertEqual(result?.standardizedFileURL.path, flat.standardizedFileURL.path)
    }

    func test_discoverGGUFModels_skipsHuggingFaceDownloadSidecars_butNotFamilyRoots() {
        // Hugging Face download sidecars under …/huggingface/download/ must not
        // be selected. A legitimate family root named `huggingface` must still
        // be discovered (review finding: bare-name exclusion was too broad).
        _ = createGGUFFile(".cache/huggingface/download/junk.gguf")
        _ = createGGUFFile("cache/huggingface/download/also-junk.gguf")
        let underHFFamily = createGGUFFile("huggingface/Qwen/Qwen2.5-7B/model.gguf")
        let real = createGGUFFile("gguf/real-model/model.gguf")

        let models = HardwareRequirements.discoverGGUFModels(
            in: [tempDirectory],
            minimumModelSize: 1
        )
        let paths = Set(models.map(\.standardizedFileURL.path))

        XCTAssertTrue(paths.contains(real.standardizedFileURL.path))
        XCTAssertTrue(
            paths.contains(underHFFamily.standardizedFileURL.path),
            "Models under a family root named 'huggingface' must remain discoverable"
        )
        XCTAssertFalse(paths.contains { $0.contains("/download/") })
    }

    func test_findGGUFModel_rejectedOnlyTree_doesNotReportDiscoveredOnNil() {
        // Name-selector miss with loadable models present must stay quiet
        // and must not print skipMessage's "Discovered N" success line.
        // Rejected-only trees are the sole stderr case (acceptedCount == 0).
        _ = createGGUFFile("loadable.gguf", size: 12)
        _ = createGGUFFile("too-small.gguf", size: 1)

        let nameMiss = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            nameContains: "mistral",
            minimumModelSize: 10
        )
        XCTAssertNil(nameMiss)

        // Rejected-only: nothing meets the size floor.
        let onlyTinyRoot = tempDirectory.appendingPathComponent("tiny-only", isDirectory: true)
        try? fm.createDirectory(at: onlyTinyRoot, withIntermediateDirectories: true)
        fm.createFile(
            atPath: onlyTinyRoot.appendingPathComponent("tiny.gguf").path,
            contents: Data(count: 1)
        )
        let rejectedOnly = HardwareRequirements.discoverGGUFModelsWithDiagnostics(
            in: [onlyTinyRoot],
            minimumModelSize: 10
        )
        XCTAssertTrue(rejectedOnly.models.isEmpty)
        XCTAssertEqual(rejectedOnly.diagnostics.acceptedCount, 0)
        XCTAssertGreaterThan(rejectedOnly.diagnostics.rejectedGGUFFileCount, 0)
        XCTAssertTrue(
            rejectedOnly.diagnostics.skipMessage.contains("none were loadable"),
            rejectedOnly.diagnostics.skipMessage
        )
    }

    func test_discoverGGUFModelsWithDiagnostics_distinguishesRejectedFromEmpty() {
        // A .gguf that fails the minimum size bound is "found but not loadable".
        _ = createGGUFFile("too-small.gguf", size: 1)

        let emptyRoot = tempDirectory.appendingPathComponent("empty-root", isDirectory: true)
        try? fm.createDirectory(at: emptyRoot, withIntermediateDirectories: true)

        let rejected = HardwareRequirements.discoverGGUFModelsWithDiagnostics(
            in: [tempDirectory],
            minimumModelSize: 10
        )
        XCTAssertTrue(rejected.models.isEmpty)
        XCTAssertGreaterThan(rejected.diagnostics.rejectedGGUFFileCount, 0)
        XCTAssertTrue(
            rejected.diagnostics.skipMessage.contains("none were loadable"),
            rejected.diagnostics.skipMessage
        )

        let empty = HardwareRequirements.discoverGGUFModelsWithDiagnostics(
            in: [emptyRoot],
            minimumModelSize: 1
        )
        XCTAssertTrue(empty.models.isEmpty)
        XCTAssertEqual(empty.diagnostics.rejectedGGUFFileCount, 0)
        XCTAssertTrue(
            empty.diagnostics.skipMessage.contains("No GGUF models found"),
            empty.diagnostics.skipMessage
        )
    }

    func test_findGGUFModel_missingEnvOverride_returnsNilRatherThanSmallestCandidate() {
        // An explicit env name-fragment that matches no candidate is a request
        // for a specific model. The function must return nil (caller skips)
        // rather than silently running against an unrelated smaller model.
        _ = createGGUFFile("alpha.gguf", size: 12)
        _ = createGGUFFile("zeta.gguf", size: 4)
        _ = createGGUFFile("tiny.gguf", size: 1)

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            environment: ["LLAMA_TEST_MODEL": "missing"],
            minimumModelSize: 2
        )

        XCTAssertNil(result, "Env name-fragment matching nothing must not fall back to another model")
    }

    func test_findGGUFModel_nameContainsMatchingNothing_returnsNil() {
        // The reported false positive: a family-targeted selector with no match
        // must yield nil, not the smallest other GGUF.
        _ = createGGUFFile("alpha.gguf", size: 12)
        _ = createGGUFFile("zeta.gguf", size: 4)

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            nameContains: "mistral",
            minimumModelSize: 1
        )

        XCTAssertNil(result, "nameContains matching nothing must not fall back to another model")
    }

    func test_findGGUFModel_envOverrideMissingWins_evenWhenNameContainsWouldMatch() {
        // Precedence lock: when the env key is present it pins the model. An
        // env miss must return nil even if the `nameContains` argument would
        // have matched — the env override is the higher-priority "pin a
        // specific model" request, so a miss skips rather than running the
        // arg-selected model.
        _ = createGGUFFile("alpha.gguf", size: 12)
        _ = createGGUFFile("mistral-7b.gguf", size: 4)

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            nameContains: "mistral",
            environment: ["LLAMA_TEST_MODEL": "missing"],
            minimumModelSize: 1
        )

        XCTAssertNil(
            result,
            "Env override miss must win over a matching nameContains arg (env pins the model)"
        )
    }

    func test_findGGUFModel_nameContainsMatching_returnsThatModel() {
        _ = createGGUFFile("alpha.gguf", size: 12)
        let mistral = createGGUFFile("mistral-7b.gguf", size: 4)

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            nameContains: "mistral",
            minimumModelSize: 1
        )

        XCTAssertEqual(result?.standardizedFileURL.path, mistral.standardizedFileURL.path)
    }

    func test_findGGUFModel_noSelector_returnsSmallestCandidate() {
        // No env override and no nameContains: the "any model" path is
        // unchanged — the smallest valid candidate wins.
        _ = createGGUFFile("alpha.gguf", size: 12)
        let smallest = createGGUFFile("zeta.gguf", size: 4)

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            minimumModelSize: 2
        )

        XCTAssertEqual(result?.standardizedFileURL.path, smallest.standardizedFileURL.path)
    }

    func test_findGGUFModel_envOverrideWinsRegardlessOfCandidateSize() {
        _ = createGGUFFile("small.gguf", size: 4)
        let selected = createGGUFFile("large.gguf", size: 24)

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            environment: ["LLAMA_TEST_MODEL": "large"],
            minimumModelSize: 1
        )

        XCTAssertEqual(result?.standardizedFileURL.path, selected.standardizedFileURL.path)
    }

    func test_findGGUFModel_respectsMaximumModelSize() {
        _ = createGGUFFile("too-large.gguf", size: 20)
        let selected = createGGUFFile("fits.gguf", size: 12)
        _ = createGGUFFile("too-small.gguf", size: 4)

        let result = HardwareRequirements.findGGUFModel(
            in: [tempDirectory],
            minimumModelSize: 10,
            maximumModelSize: 15
        )

        XCTAssertEqual(result?.standardizedFileURL.path, selected.standardizedFileURL.path)
    }

    func test_publicFindGGUFModel_withoutOptInDoesNotScanDefaultDirectories() {
        let result = HardwareRequirements.findGGUFModel(environment: [:])

        XCTAssertNil(result)
    }

    func test_findGGUFModel_absolutePathThatFailsValidation_returnsNilRatherThanFallingBack() {
        // When LLAMA_TEST_MODEL is an absolute path that points at a
        // non-existent file, findGGUFModel must return nil rather than
        // silently falling back to a different discovered model.
        //
        // We exercise the public path that consults `modelSearchDirectories()`.
        // Because that directory is unlikely to contain any GGUFs in a test
        // context, we only need to confirm the call returns nil — not that it
        // skips a valid candidate. The invariant under test is that the caller
        // does NOT enable unrestricted discovery when given a path-shaped
        // selector, so we can't accidentally load a random model from disk.
        let nonExistentPath = tempDirectory.appendingPathComponent("does-not-exist.gguf").path
        let result = HardwareRequirements.findGGUFModel(
            environment: ["LLAMA_TEST_MODEL": nonExistentPath]
        )

        XCTAssertNil(result, "Absolute-path override that fails validation must not fall back to discovered models")
    }

    func test_isValidGGUFModel_rejectsDirectoriesAndTinyFiles() {
        let directory = tempDirectory.appendingPathComponent("fake.gguf", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tiny = createGGUFFile("tiny.gguf", size: 1)

        XCTAssertFalse(HardwareRequirements.isValidGGUFModel(directory, minimumModelSize: 1))
        XCTAssertFalse(HardwareRequirements.isValidGGUFModel(tiny, minimumModelSize: 2))
        XCTAssertFalse(HardwareRequirements.isValidGGUFModel(tiny, minimumModelSize: 1, maximumModelSize: 0))
    }

    func test_discoverGGUFModels_missingRootBesideModel() {
        let missing = tempDirectory.appendingPathComponent("missing", isDirectory: true)
        let grouped = createGGUFFile("gguf/Local/model.gguf")

        let result = HardwareRequirements.discoverGGUFModelsWithDiagnostics(
            in: [missing, tempDirectory],
            minimumModelSize: 1
        )

        XCTAssertEqual(result.models.map(\.standardizedFileURL.path), [grouped.standardizedFileURL.path])
        XCTAssertEqual(result.diagnostics.scannedDirectoryCount, 3)
        XCTAssertEqual(result.diagnostics.unreadableDirectoryCount, 0)
    }

    // Sabotage-evidence:
    //   M1: disable the `mmproj` exclusion → selects the smaller projector;
    //       the URL assertion fails (verified 2026-09-23).
    //   M2: change the expected URL to the projector → the URL assertion fails.
    //   M3: no hardware capability gate; this isolated fixture always runs.
    func test_findGGUFModel_skipsProjectorSidecarAndSelectsGroupedLanguageModel() {
        let missing = tempDirectory.appendingPathComponent("missing", isDirectory: true)
        let projector = createGGUFFile("gguf/Qwen3-VL/mmproj-Qwen3-VL.gguf", size: 4)
        let languageModel = createGGUFFile("gguf/Qwen3-VL/Qwen3-VL-Q4.gguf", size: 12)

        let selected = HardwareRequirements.findGGUFModel(
            in: [missing, tempDirectory],
            nameContains: "Qwen3-VL",
            minimumModelSize: 1
        )

        XCTAssertEqual(selected?.standardizedFileURL.path, languageModel.standardizedFileURL.path)
        XCTAssertTrue(HardwareRequirements.isValidGGUFModel(projector, minimumModelSize: 1),
                      "An explicit projector path must retain normal GGUF validation")
    }

    func test_discoverGGUFModels_unreadableExistingRootIsReported() throws {
        let unreadable = tempDirectory.appendingPathComponent("unreadable", isDirectory: true)
        try fm.createDirectory(at: unreadable, withIntermediateDirectories: true)
        let fileManager = UnreadableGGUFDirectoryFileManager(unreadablePath: unreadable.path)

        let result = HardwareRequirements.discoverGGUFModelsWithDiagnostics(
            in: [unreadable],
            fileManager: fileManager,
            minimumModelSize: 1
        )

        XCTAssertTrue(result.models.isEmpty)
        XCTAssertEqual(result.diagnostics.scannedDirectoryCount, 1)
        XCTAssertEqual(result.diagnostics.unreadableDirectoryCount, 1)
        XCTAssertTrue(result.diagnostics.skipMessage.contains("Could not read 1 GGUF search directory"),
                      result.diagnostics.skipMessage)
    }

    func test_discoverGGUFModels_missingOnlyRootHasNoModelAndNoReadFailure() {
        let missing = tempDirectory.appendingPathComponent("missing", isDirectory: true)
        let result = HardwareRequirements.discoverGGUFModelsWithDiagnostics(
            in: [missing],
            minimumModelSize: 1
        )

        XCTAssertTrue(result.models.isEmpty)
        XCTAssertEqual(result.diagnostics.scannedDirectoryCount, 0)
        XCTAssertEqual(result.diagnostics.unreadableDirectoryCount, 0)
        XCTAssertTrue(result.diagnostics.skipMessage.contains("No GGUF models found"),
                      result.diagnostics.skipMessage)
    }

    func test_publicFindGGUFModel_liveDefaultRoots() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MANIFOLD_DISCOVER_LOCAL_MODELS"] == "1",
                          "Set MANIFOLD_DISCOVER_LOCAL_MODELS=1 to scan real model directories")
        // Keep ambient LLAMA_TEST_MODEL out of this call: an absolute override
        // bypasses discovery and would make the live path assertion vacuous.
        guard let model = HardwareRequirements.findGGUFModel(
            environment: ["MANIFOLD_DISCOVER_LOCAL_MODELS": "1"]
        ) else {
            throw XCTSkip("No GGUF models found under default search roots")
        }
        XCTAssertFalse(model.lastPathComponent.lowercased().hasPrefix("mmproj"))
        XCTAssertTrue(fm.fileExists(atPath: model.path))
    }

    @discardableResult
    private func createGGUFFile(_ relativePath: String, size: Int = 4) -> URL {
        let url = tempDirectory.appendingPathComponent(relativePath)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data(count: size))
        return url
    }
}

private final class UnreadableGGUFDirectoryFileManager: FileManager {
    private let unreadablePath: String

    init(unreadablePath: String) {
        self.unreadablePath = unreadablePath
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if url.path == unreadablePath {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
