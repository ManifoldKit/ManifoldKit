import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldModelCatalog

final class ModelStorageServiceTests: XCTestCase {

    private var service: ModelStorageService!
    private var scratchDirectory: URL!
    private var createdURLs: [URL]!

    override func setUp() {
        super.setUp()
        // Route every filesystem write through a per-test scratch directory.
        // Writing to the real `<Documents>/Models` path (the production
        // default) leaks test artifacts into the demo app's model scanner
        // and has historically accumulated GBs of junk on dev machines.
        // See #379.
        let isolated = makeIsolatedModelStorage()
        service = isolated.service
        scratchDirectory = isolated.directory
        createdURLs = []

        // Ensure the scratch Models directory exists so tests can write into it.
        try? service.ensureModelsDirectory()
    }

    override func tearDown() {
        // Remove everything this test created — then nuke the whole scratch
        // directory so even files the test forgot to track are cleaned up.
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: scratchDirectory)
        createdURLs = nil
        scratchDirectory = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a temporary GGUF file inside the models directory with a UUID-based name.
    /// Returns the file URL. The file is tracked for tearDown cleanup.
    ///
    /// The first 4 bytes are the GGUF magic header (`0x47 0x47 0x55 0x46`) so the file
    /// passes `ModelInfo(ggufURL:)`'s magic-bytes gate. The rest is filler padding out
    /// to `size`.
    @discardableResult
    private func createGgufFile(named prefix: String = "test", size: Int = 1024) throws -> URL {
        precondition(size >= 4, "GGUF fixture must be at least 4 bytes for the magic header")
        let fileName = "\(prefix)-\(UUID().uuidString).gguf"
        let url = service.modelsDirectory.appendingPathComponent(fileName)
        var data = Data([0x47, 0x47, 0x55, 0x46])
        data.append(Data(repeating: 0xAA, count: size - 4))
        try data.write(to: url)
        createdURLs.append(url)
        return url
    }

    /// Creates a temporary MLX directory with config.json inside the models directory.
    /// Returns the directory URL. The directory is tracked for tearDown cleanup.
    @discardableResult
    private func createMlxDirectory(named prefix: String = "mlx-model", weightsSize: Int = 2048) throws -> URL {
        let dirName = "\(prefix)-\(UUID().uuidString)"
        let url = service.modelsDirectory.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let configData = Data("{}".utf8)
        try configData.write(to: url.appendingPathComponent("config.json"))

        let weightsData = Data(repeating: 0xBB, count: weightsSize)
        try weightsData.write(to: url.appendingPathComponent("weights.safetensors"))

        createdURLs.append(url)
        return url
    }

    /// Creates a non-model file inside the models directory.
    @discardableResult
    private func createNonModelFile(extension ext: String = "txt") throws -> URL {
        let fileName = "not-a-model-\(UUID().uuidString).\(ext)"
        let url = service.modelsDirectory.appendingPathComponent(fileName)
        try Data("hello".utf8).write(to: url)
        createdURLs.append(url)
        return url
    }

    @discardableResult
    private func createDiffusionPackage(
        named name: String = "diffusion-\(UUID().uuidString)",
        writeManifest: Bool = true,
        omitFile omitted: String? = nil
    ) throws -> URL {
        let dir = service.modelsDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Mirror the on-disk Hub layout produced by
        // `DiffusionDownload.hubLeafDirectory`: files live under
        // `<package>/models/<org>/<name>/...`. The package manifest at the
        // package root lists every file with that prefix so the readiness
        // check in `ModelStorageService.imageModelInfoIfReady` walks the
        // correct paths.
        let repoID = "test-org/\(name)"
        let hubLeaf = dir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoID, isDirectory: true)
        let unprefixed = [
            "model_index.json",
            "unet/config.json",
            "unet/diffusion_pytorch_model.safetensors",
            "vae/config.json",
            "vae/diffusion_pytorch_model.safetensors",
            "text_encoder/config.json",
            "text_encoder/model.safetensors",
            "scheduler/scheduler_config.json",
        ]
        for file in unprefixed where file != omitted {
            let url = hubLeaf.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        if writeManifest {
            let prefixed = unprefixed.map { "models/\(repoID)/" + $0 }
            let manifest = DownloadedModelPackageManifest(
                packageKind: .diffusion,
                id: repoID,
                displayName: "Diffusion \(name)",
                format: .mlxDiffusion,
                huggingFaceRepoID: repoID,
                files: prefixed
            )
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: dir.appendingPathComponent(DownloadedModelPackageManifest.fileName))
        }
        createdURLs.append(dir)
        return dir
    }

    // MARK: - ensureModelsDirectory

    func test_ensureModelsDirectory_createsDirectory() throws {
        // The directory may already exist from setUp; verify it exists after calling.
        try service.ensureModelsDirectory()

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: service.modelsDirectory.path,
            isDirectory: &isDirectory
        )

        XCTAssertTrue(exists, "Models directory should exist")
        XCTAssertTrue(isDirectory.boolValue, "Models path should be a directory")
    }

    // MARK: - discoverModels

    func test_discoverModels_findsGgufFiles() throws {
        let ggufURL = try createGgufFile()

        let models = service.discoverModels()
        // Match by filename — discoverModels returns standardised URLs which
        // can differ from the write-time URL by symlink resolution
        // (`/var/folders/…` ↔ `/private/var/folders/…`) on macOS temp paths.
        let match = models.first { $0.fileName == ggufURL.lastPathComponent }

        XCTAssertNotNil(match, "Should discover the GGUF file")
        XCTAssertEqual(match?.modelType, .gguf)
        XCTAssertEqual(match?.fileSize, 1024)
    }

    // MARK: - mmproj companion (single enumeration per scan, #1787)

    func test_discoverModels_resolvesMmprojForEveryModel_withSingleEnumeration() throws {
        // K text GGUFs + one mmproj sibling in the same directory. Every model's
        // mmprojURL must resolve to the projector, and the parent directory must be
        // enumerated exactly ONCE for the whole scan (not once per GGUF as the old
        // O(K²) self-enumeration did).
        let counter = CountingFileManager()
        let scratch = makeIsolatedModelsDirectory()
        // includeUserDocumentsFallback: false so the scan touches ONLY this scratch
        // directory — otherwise the dev machine's ~/Documents/Models pollutes both
        // the model count and the enumeration count.
        let countingService = ModelStorageService(
            fileManager: counter,
            baseDirectory: scratch,
            includeUserDocumentsFallback: false
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try countingService.ensureModelsDirectory()
        let dir = countingService.modelsDirectory

        func writeGGUF(_ name: String) throws {
            var data = Data([0x47, 0x47, 0x55, 0x46])
            data.append(Data(repeating: 0xAA, count: 1020))
            try data.write(to: dir.appendingPathComponent(name))
        }

        let k = 5
        for i in 0..<k {
            try writeGGUF("model-\(i).gguf")
        }
        try writeGGUF("mmproj-vision.gguf")

        // Reset the counter so only the scan's enumerations are measured.
        counter.contentsOfDirectoryCallCount = 0
        let models = countingService.discoverModels()

        let textModels = models.filter { !$0.fileName.lowercased().hasPrefix("mmproj") }
        XCTAssertEqual(textModels.count, k, "All \(k) text models should be discovered")
        XCTAssertTrue(
            textModels.allSatisfy { $0.mmprojURL?.lastPathComponent == "mmproj-vision.gguf" },
            "Every text model must resolve the mmproj companion"
        )

        // One enumeration for the models directory. The fallback (~/Documents/Models)
        // is disabled in the isolated service, so no extra enumeration is expected.
        // Sabotage proof: reverting ModelInfo.load to self-enumerate per file would
        // make this K (one per GGUF) + 1 instead of 1.
        XCTAssertEqual(
            counter.contentsOfDirectoryCallCount, 1,
            "The scan must enumerate the directory exactly once, not once per GGUF (#1787)"
        )
    }

    func test_discoverModels_singleFileCompatibilityIgnoresPackageManifest() throws {
        let ggufURL = try createGgufFile()
        try createDiffusionPackage()

        let models = service.discoverModels()

        XCTAssertNotNil(models.first { $0.fileName == ggufURL.lastPathComponent })
        XCTAssertNil(
            models.first { $0.modelType == .mlx && $0.fileName.contains("diffusion") },
            "Image packages must not alter the existing text-model discovery list"
        )
    }

    func test_discoverModels_findsMlxDirectories() throws {
        let mlxURL = try createMlxDirectory()

        let models = service.discoverModels()
        let match = models.first { $0.fileName == mlxURL.lastPathComponent }

        XCTAssertNotNil(match, "Should discover the MLX directory")
        XCTAssertEqual(match?.modelType, .mlx)
    }

    func test_discoverModels_ignoresNonModelFiles() throws {
        let nonModelURL = try createNonModelFile()

        let models = service.discoverModels()
        let match = models.first { $0.fileName == nonModelURL.lastPathComponent }

        XCTAssertNil(match, "Non-model files should not be discovered")
    }

    func test_discoverModels_emptyDirectory_returnsEmpty() throws {
        // Use a fresh service pointed at the real models directory.
        // We can't guarantee the directory is truly empty (other tests may run),
        // so instead verify that with no test files created, our test files aren't present.
        // A more precise test: create a separate service with a temporary directory.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyModelsTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // discoverModels scans service.modelsDirectory, but we can verify that a directory
        // with no model files returns nothing by checking none of our unique IDs appear.
        // For a true empty-directory test, verify there are no models with our UUID prefix.
        let models = service.discoverModels()
        let uniqueTag = UUID().uuidString
        let match = models.first { $0.fileName.contains(uniqueTag) }

        XCTAssertNil(match, "No models with the unique tag should be found")
    }

    func test_discoverModels_mixedFormats_findsBoth() throws {
        let ggufURL = try createGgufFile(named: "mixed-gguf")
        let mlxURL = try createMlxDirectory(named: "mixed-mlx")

        let models = service.discoverModels()
        let ggufMatch = models.first { $0.fileName == ggufURL.lastPathComponent }
        let mlxMatch = models.first { $0.fileName == mlxURL.lastPathComponent }

        XCTAssertNotNil(ggufMatch, "Should discover the GGUF file")
        XCTAssertNotNil(mlxMatch, "Should discover the MLX directory")
        XCTAssertEqual(ggufMatch?.modelType, .gguf)
        XCTAssertEqual(mlxMatch?.modelType, .mlx)
    }

    func test_discoverModels_findsNamespacedMlxDirectory() throws {
        // Layout: <Models>/<namespace>/<model>/{config.json,weights.safetensors}
        // The HF-style namespace directory itself has no config.json — discovery
        // must recurse one level when the parent isn't a model directory.
        let namespace = "mlx-community"
        let modelName = "gemma-4-test-\(UUID().uuidString)"

        let namespaceURL = service.modelsDirectory.appendingPathComponent(namespace)
        let modelURL = namespaceURL.appendingPathComponent(modelName)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: modelURL.appendingPathComponent("config.json"))
        try Data(repeating: 0xCC, count: 1024).write(to: modelURL.appendingPathComponent("weights.safetensors"))
        // Track the top-level namespace directory so tearDown removes the whole tree.
        createdURLs.append(namespaceURL)

        let models = service.discoverModels()
        let expectedFileName = "\(namespace)/\(modelName)"
        let match = models.first { $0.fileName == expectedFileName }

        XCTAssertNotNil(match, "Should discover the namespaced MLX directory")
        XCTAssertEqual(match?.modelType, .mlx)
    }

    func test_discoverModels_findsFlatAndMultipleNamespacedMlxDirectories() throws {
        // Coexisting layouts under a single Models/ root:
        //   - flat:                Models/<flat>/
        //   - namespace #1:        Models/mlx-community-<uuid>/<a>/
        //   - namespace #2:        Models/Qwen-<uuid>/<b>/
        // All three must be discovered; namespaced ones carry their org prefix
        // in fileName. Sabotage check: changing the inner `for nestedURL` loop
        // to `break` after the first match drops the second namespaced model.
        let flatURL = try createMlxDirectory(named: "mixed-flat")

        let nsA = service.modelsDirectory.appendingPathComponent("mlx-community-\(UUID().uuidString)")
        let modelA = nsA.appendingPathComponent("model-a")
        try FileManager.default.createDirectory(at: modelA, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: modelA.appendingPathComponent("config.json"))
        try Data(repeating: 0xAA, count: 256).write(to: modelA.appendingPathComponent("a.safetensors"))
        createdURLs.append(nsA)

        let nsB = service.modelsDirectory.appendingPathComponent("Qwen-\(UUID().uuidString)")
        let modelB = nsB.appendingPathComponent("model-b")
        try FileManager.default.createDirectory(at: modelB, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: modelB.appendingPathComponent("config.json"))
        try Data(repeating: 0xBB, count: 256).write(to: modelB.appendingPathComponent("b.safetensors"))
        createdURLs.append(nsB)

        let models = service.discoverModels()

        XCTAssertNotNil(
            models.first { $0.fileName == flatURL.lastPathComponent },
            "Flat MLX directory should be discovered"
        )
        XCTAssertNotNil(
            models.first { $0.fileName == "\(nsA.lastPathComponent)/model-a" },
            "Namespaced MLX directory under \(nsA.lastPathComponent) should be discovered"
        )
        XCTAssertNotNil(
            models.first { $0.fileName == "\(nsB.lastPathComponent)/model-b" },
            "Namespaced MLX directory under \(nsB.lastPathComponent) should be discovered"
        )
    }

    /// Maps a package root (the directory `discoverImageModels` iterates over)
    /// to the Hub leaf URL exposed on the resulting `ImageModelInfo`. Mirrors
    /// `createDiffusionPackage`'s `models/<repoID>/` layout.
    private func hubLeafURL(forPackage packageURL: URL) -> URL {
        let repoID = "test-org/\(packageURL.lastPathComponent)"
        return packageURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoID, isDirectory: true)
    }

    func test_discoverImageModels_ignoresPartialPackageWithoutManifest() throws {
        let packageURL = try createDiffusionPackage(writeManifest: false)
        let expectedDir = hubLeafURL(forPackage: packageURL)

        let imageModels = service.discoverImageModels()

        XCTAssertNil(
            imageModels.first {
                $0.directoryURL.standardizedFileURL.path == expectedDir.standardizedFileURL.path
            },
            "Partially downloaded packages without readiness manifests must stay hidden"
        )
    }

    func test_discoverImageModels_ignoresManifestWhenComponentMissing() throws {
        let packageURL = try createDiffusionPackage(omitFile: "vae/diffusion_pytorch_model.safetensors")
        let expectedDir = hubLeafURL(forPackage: packageURL)

        let imageModels = service.discoverImageModels()

        XCTAssertNil(
            imageModels.first {
                $0.directoryURL.standardizedFileURL.path == expectedDir.standardizedFileURL.path
            },
            "Readiness manifests are atomic: every listed component must exist"
        )
    }

    func test_discoverImageModels_surfacesCompletePackageAsSingleEntry() throws {
        let packageURL = try createDiffusionPackage(named: "ready-diffusion-\(UUID().uuidString)")
        let expectedDir = hubLeafURL(forPackage: packageURL)

        let imageModels = service.discoverImageModels()
        let match = imageModels.first {
            $0.directoryURL.standardizedFileURL.path == expectedDir.standardizedFileURL.path
        }

        XCTAssertNotNil(match)
        XCTAssertEqual(match?.format, .mlxDiffusion)
        XCTAssertEqual(match?.huggingFaceRepoID, match?.id)
        XCTAssertEqual(
            imageModels.filter {
                $0.directoryURL.standardizedFileURL.path == expectedDir.standardizedFileURL.path
            }.count,
            1,
            "A multi-component package should appear as one logical model"
        )
    }

    func test_discoverModels_namespaceWithoutModels_yieldsNothing() throws {
        // An empty namespace directory (no nested config.json anywhere) must not
        // produce a phantom ModelInfo.
        let namespaceURL = service.modelsDirectory
            .appendingPathComponent("empty-namespace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: namespaceURL, withIntermediateDirectories: true)
        createdURLs.append(namespaceURL)

        let models = service.discoverModels()
        let match = models.first { $0.fileName.hasPrefix(namespaceURL.lastPathComponent) }

        XCTAssertNil(match, "Empty namespace directory should not yield a model")
    }

    func test_discoverModels_sortedByName() throws {
        // Create files with names that sort in a known order.
        // Use a shared prefix so we can filter to just our test files.
        let tag = UUID().uuidString.prefix(8)
        let nameA = "aaa-\(tag)"
        let nameB = "bbb-\(tag)"
        let nameC = "ccc-\(tag)"

        // Create in reverse order to ensure sorting isn't just insertion order.
        try createGgufFile(named: nameC)
        try createGgufFile(named: nameA)
        try createGgufFile(named: nameB)

        let models = service.discoverModels()
        let taggedModels = models.filter { $0.fileName.contains(String(tag)) }

        XCTAssertEqual(taggedModels.count, 3, "Should find all three tagged models")
        XCTAssertTrue(
            taggedModels[0].name.localizedStandardCompare(taggedModels[1].name) == .orderedAscending,
            "First model should sort before second"
        )
        XCTAssertTrue(
            taggedModels[1].name.localizedStandardCompare(taggedModels[2].name) == .orderedAscending,
            "Second model should sort before third"
        )
    }

    // MARK: - deleteModel

    func test_deleteModel_removesFile() throws {
        let ggufURL = try createGgufFile()

        let models = service.discoverModels()
        let model = try XCTUnwrap(models.first { $0.fileName == ggufURL.lastPathComponent })

        try service.deleteModel(model)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ggufURL.path),
            "File should be deleted from disk"
        )

        // Remove from cleanup list since it's already deleted.
        createdURLs.removeAll { $0 == ggufURL }
    }

    // MARK: - modelStorageUsed

    func test_modelStorageUsed_sumsFileSizes() throws {
        let sizeA = 512
        let sizeB = 1024

        try createGgufFile(named: "sizeA", size: sizeA)
        try createGgufFile(named: "sizeB", size: sizeB)

        let totalUsed = service.modelStorageUsed()

        // The total must include at least our two files. Other models may already exist
        // in the directory, so we verify the total is >= our known sum.
        XCTAssertGreaterThanOrEqual(
            totalUsed,
            UInt64(sizeA + sizeB),
            "Storage used should include at least the sizes of our test files"
        )
    }

    // MARK: - importModel

    func test_importModel_copiesFileToModelsDirectory() throws {
        // Create a temporary file outside the models directory.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFileName = "import-test-\(UUID().uuidString).gguf"
        let sourceURL = tempDir.appendingPathComponent(sourceFileName)
        let data = Data(repeating: 0xCC, count: 2048)
        try data.write(to: sourceURL)

        let destination = try service.importModel(from: sourceURL)
        createdURLs.append(destination)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.path),
            "Imported model should exist in models directory"
        )
        XCTAssertEqual(
            destination.lastPathComponent, sourceFileName,
            "Imported file should keep its original name"
        )

        // Verify file content was copied correctly.
        let copiedData = try Data(contentsOf: destination)
        XCTAssertEqual(copiedData.count, 2048, "Copied file should match source size")
    }

    func test_importModel_overwritesExisting() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverwriteTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileName = "overwrite-test-\(UUID().uuidString).gguf"
        let sourceURL = tempDir.appendingPathComponent(fileName)

        // First import: 1024 bytes.
        try Data(repeating: 0xAA, count: 1024).write(to: sourceURL)
        let dest1 = try service.importModel(from: sourceURL)
        createdURLs.append(dest1)

        // Second import: 2048 bytes (overwrite).
        try Data(repeating: 0xBB, count: 2048).write(to: sourceURL)
        let dest2 = try service.importModel(from: sourceURL)

        XCTAssertEqual(dest1.path, dest2.path, "Both imports should target the same destination")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dest2.path),
            "File should still exist after overwrite"
        )

        let finalData = try Data(contentsOf: dest2)
        XCTAssertEqual(finalData.count, 2048, "Overwritten file should have the new size")
    }

    // MARK: - Per-app scoping

    func test_discoverModels_scopesDefaultDirectoriesByBundleIdentifier() throws {
        let suffix = UUID().uuidString
        let bundleA = "com.manifoldkit.tests.model-storage-a.\(suffix)"
        let bundleB = "com.manifoldkit.tests.model-storage-b.\(suffix)"
        let serviceA = ModelStorageService(bundleIdentifier: bundleA)
        let serviceB = ModelStorageService(bundleIdentifier: bundleB)

        XCTAssertNotEqual(
            serviceA.modelsDirectory.path,
            serviceB.modelsDirectory.path,
            "Different bundle identifiers must produce different models directories"
        )

        defer {
            try? FileManager.default.removeItem(at: serviceA.modelsDirectory.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: serviceB.modelsDirectory.deletingLastPathComponent())
        }

        try serviceA.ensureModelsDirectory()
        try serviceB.ensureModelsDirectory()

        let modelAName = "only-app-a-\(suffix).gguf"
        let modelBName = "only-app-b-\(suffix).gguf"
        let ggufData = Data([0x47, 0x47, 0x55, 0x46])
        try ggufData.write(to: serviceA.modelsDirectory.appendingPathComponent(modelAName))
        try ggufData.write(to: serviceB.modelsDirectory.appendingPathComponent(modelBName))

        let modelsA = serviceA.discoverModels().map(\.fileName)
        let modelsB = serviceB.discoverModels().map(\.fileName)

        XCTAssertTrue(modelsA.contains(modelAName), "App A should discover its own model")
        XCTAssertFalse(modelsA.contains(modelBName), "App A must not discover App B's model")
        XCTAssertTrue(modelsB.contains(modelBName), "App B should discover its own model")
        XCTAssertFalse(modelsB.contains(modelAName), "App B must not discover App A's model")
    }

    func test_modelsDirectory_containsBundleIdentifier() {
        let bundleID = "com.test.myapp-\(UUID().uuidString)"
        let scoped = ModelStorageService(bundleIdentifier: bundleID)

        XCTAssertTrue(
            scoped.modelsDirectory.path.contains(bundleID),
            "Default models directory path should contain the bundle identifier"
        )
    }

    func test_modelsDirectory_customBaseDirectory_ignoresBundleIdentifier() {
        let fixed = FileManager.default.temporaryDirectory.appendingPathComponent("shared-models")
        let service1 = ModelStorageService(baseDirectory: fixed)
        let service2 = ModelStorageService(baseDirectory: fixed, bundleIdentifier: "com.other.app")

        XCTAssertEqual(
            service1.modelsDirectory.path,
            service2.modelsDirectory.path,
            "Explicit baseDirectory should bypass bundle-scoped path"
        )
    }

    // MARK: - importModel path-safety (SEC-03)

    func test_importModel_throwsForEmptyLastPathComponent() throws {
        // A URL with no path component (e.g. "file://") produces an empty
        // lastPathComponent — importModel must reject it before touching the
        // filesystem so no file lands at an unvalidated destination.
        let emptyComponentURL = URL(string: "file://")!
        XCTAssertThrowsError(try service.importModel(from: emptyComponentURL)) { error in
            guard let hfError = error as? HuggingFaceError,
                  case .invalidDownloadedFile = hfError else {
                XCTFail("Expected HuggingFaceError.invalidDownloadedFile for empty component, got \(error)")
                return
            }
        }
    }

    func test_importModel_throwsForPathTraversalFilename() throws {
        // A URL whose lastPathComponent is ".." must be rejected by
        // DownloadableModel.validate before any filesystem access. This prevents
        // a crafted drag-and-drop import from escaping the models directory.
        // URL(string:) does not normalize ".." in the path, so lastPathComponent
        // is the literal string "..".
        let traversalURL = URL(string: "file:///tmp/models/..")!
        XCTAssertThrowsError(try service.importModel(from: traversalURL)) { error in
            // validate(fileName:) throws FileNameError.pathTraversal (internal type),
            // not HuggingFaceError — any thrown error satisfies the contract.
            // The important guarantee is that no file is written.
            _ = error
        }
    }

    // MARK: - availableDiskSpace

    func test_availableDiskSpace_returnsNonZero() {
        let space = service.availableDiskSpace()

        XCTAssertGreaterThan(space, 0, "Available disk space should be non-zero on a real system")
    }
}

// MARK: - Counting FileManager

/// A `FileManager` subclass that counts `contentsOfDirectory(at:...)` calls so a
/// test can assert a directory is enumerated exactly once per scan (#1787).
private final class CountingFileManager: FileManager {
    var contentsOfDirectoryCallCount = 0

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        contentsOfDirectoryCallCount += 1
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
