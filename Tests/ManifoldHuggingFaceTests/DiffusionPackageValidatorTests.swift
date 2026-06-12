import XCTest
@testable import ManifoldInference
@testable import ManifoldHuggingFace

final class DiffusionPackageValidatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = Self.artifactsRoot().appendingPathComponent("DiffusionPackageValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    func test_validatePackageName_rejectsTraversalShapes() {
        XCTAssertNoThrow(try DiffusionPackageValidator.validatePackageName("stable-diffusion-package"))
        XCTAssertThrowsError(try DiffusionPackageValidator.validatePackageName("../escape"))
        XCTAssertThrowsError(try DiffusionPackageValidator.validatePackageName(".hidden"))
    }

    func test_diffusionRole_mapsSupportedComponents() {
        XCTAssertEqual(DiffusionPackageValidator.diffusionRole(for: "model_index.json"), .manifest)
        XCTAssertEqual(DiffusionPackageValidator.diffusionRole(for: "unet/config.json"), .submoduleConfig)
        XCTAssertEqual(DiffusionPackageValidator.diffusionRole(for: "unet/diffusion_pytorch_model.safetensors"), .weights)
        XCTAssertNil(DiffusionPackageValidator.diffusionRole(for: "README.md"))
    }

    func test_validatePackage_requiresDenoiserAndVAE() throws {
        try write("model_index.json", Data(#"{"_class_name":"StableDiffusionPipeline"}"#.utf8))
        try write("vae/config.json", Data(#"{"sample_size":64}"#.utf8))
        try write("vae/diffusion_pytorch_model.safetensors", Self.safetensorsBlob())

        XCTAssertThrowsError(try DiffusionPackageValidator.validatePackage(
            at: root,
            files: [
                "model_index.json",
                "vae/config.json",
                "vae/diffusion_pytorch_model.safetensors",
            ]
        ))

        try write("unet/diffusion_pytorch_model.safetensors", Self.safetensorsBlob())
        XCTAssertNoThrow(try DiffusionPackageValidator.validatePackage(
            at: root,
            files: [
                "model_index.json",
                "vae/config.json",
                "vae/diffusion_pytorch_model.safetensors",
                "unet/diffusion_pytorch_model.safetensors",
            ]
        ))
    }

    func test_writePackageManifest_recordsDiffusionPackageShape() throws {
        let model = DownloadableModel(
            repoID: "test/diffusion",
            fileName: "snapshot",
            displayName: "Diffusion Model",
            modelType: .mlx,
            sizeBytes: 123,
            packageKind: .diffusion
        )
        let files = [
            "unet/diffusion_pytorch_model.safetensors",
            "model_index.json",
            "vae/config.json",
        ]

        try DiffusionPackageValidator.writePackageManifest(for: model, files: files, in: root)

        let manifestURL = root.appendingPathComponent(DownloadedModelPackageManifest.fileName)
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(DownloadedModelPackageManifest.self, from: data)
        XCTAssertEqual(manifest.packageKind, .diffusion)
        XCTAssertEqual(manifest.id, model.repoID)
        XCTAssertEqual(manifest.displayName, model.displayName)
        XCTAssertEqual(manifest.format, .mlxDiffusion)
        XCTAssertEqual(manifest.huggingFaceRepoID, model.repoID)
        XCTAssertEqual(manifest.files, files.sorted())
    }

    private func write(_ relativePath: String, _ data: Data) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private static func safetensorsBlob() -> Data {
        let header = Data(#"{"x":{"dtype":"F16","shape":[1],"data_offsets":[0,2]}}"#.utf8)
        var prefix = Data(count: 8)
        let length = UInt64(header.count).littleEndian
        prefix.withUnsafeMutableBytes { $0.storeBytes(of: length, as: UInt64.self) }
        return prefix + header + Data(repeating: 0, count: 2)
    }

    private static func artifactsRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tmp/test-artifacts", isDirectory: true)
    }
}
