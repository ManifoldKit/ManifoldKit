import XCTest
@testable import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldHuggingFace
import HuggingFace

final class DiffusionDownloadTests: XCTestCase {

    private var tempDir: URL!
    private var stubbedURLs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffusionDL-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        stubbedURLs = []
    }

    override func tearDownWithError() throws {
        // Per-test stub cleanup only — never reset() because parallel suites
        // share MockURLProtocol's static stub registry.
        for url in stubbedURLs {
            MockURLProtocol.unstub(url: url)
        }
        stubbedURLs = []
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Builds a session whose host is unique to this test run and returns the
    /// `HuggingFaceService` that points at it. Tests stub against this host
    /// only — concurrent tests can't collide.
    private func makeService() -> (service: HuggingFaceService, baseURL: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let host = "\(UUID().uuidString.lowercased()).diffusion.test"
        let hostURL = URL(string: "https://\(host)")!
        let hubClient = HubClient(
            session: session,
            host: hostURL,
            userAgent: "ManifoldKitDiffusionTests/1.0",
            cache: nil
        )
        return (HuggingFaceService(hubClient: hubClient), hostURL)
    }

    private func stubFile(repoURL: URL, repoID: String, relativePath: String, data: Data) {
        let url = downloadFileURL(repoURL: repoURL, repoID: repoID, relativePath: relativePath)
        MockURLProtocol.stub(
            url: url,
            response: .immediate(
                data: data,
                statusCode: 200,
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Content-Length": String(data.count),
                ]
            )
        )
        stubbedURLs.append(url)
    }

    private func stubFileError(repoURL: URL, repoID: String, relativePath: String, statusCode: Int) {
        let url = downloadFileURL(repoURL: repoURL, repoID: repoID, relativePath: relativePath)
        MockURLProtocol.stub(
            url: url,
            response: .immediate(data: Data("not found".utf8), statusCode: statusCode)
        )
        stubbedURLs.append(url)
    }

    /// Mirrors `HuggingFaceService.downloadURL(repoID:filePath:)` but with a
    /// custom host. The test session's stubs are keyed by absolute URL, so we
    /// need to construct the same URL the service will produce.
    ///
    /// Important: the production helper builds `https://huggingface.co/...`,
    /// not the mock host. To intercept, we rewrite the host to ours.
    private func downloadFileURL(repoURL: URL, repoID: String, relativePath: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = repoURL.host
        components.percentEncodedPath = "/" + ([repoID, "resolve", "main"]
            + relativePath.components(separatedBy: "/"))
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        return components.url!
    }

    private func makeSafetensorsBlob(payloadByteCount: Int = 4) -> Data {
        let headerJSON = #"{"foo":{"dtype":"F16","shape":[2],"data_offsets":[0,4]}}"#
        let headerBytes = Data(headerJSON.utf8)
        var prefix = Data(count: 8)
        let headerLen = UInt64(headerBytes.count).littleEndian
        prefix.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: headerLen, as: UInt64.self)
        }
        var blob = prefix
        blob.append(headerBytes)
        blob.append(Data(repeating: 0, count: payloadByteCount))
        return blob
    }

    private func sd21ManifestJSON() -> String {
        #"""
        {
          "_class_name": "StableDiffusionPipeline",
          "scheduler": ["PNDMScheduler", "scheduler"],
          "unet": ["UNet2DConditionModel", "unet"],
          "vae": ["AutoencoderKL", "vae"],
          "text_encoder": ["CLIPTextModel", "text_encoder"],
          "tokenizer": ["CLIPTokenizer", "tokenizer"]
        }
        """#
    }

    private func sdxlManifestJSON() -> String {
        #"""
        {
          "_class_name": "StableDiffusionXLPipeline",
          "scheduler": ["EulerDiscreteScheduler", "scheduler"],
          "unet": ["UNet2DConditionModel", "unet"],
          "vae": ["AutoencoderKL", "vae"],
          "text_encoder": ["CLIPTextModel", "text_encoder"],
          "text_encoder_2": ["CLIPTextModelWithProjection", "text_encoder_2"],
          "tokenizer": ["CLIPTokenizer", "tokenizer"],
          "tokenizer_2": ["CLIPTokenizer", "tokenizer_2"]
        }
        """#
    }

    /// Stubs the SD 2.1 file set against the given service's host.
    private func stubSD21Set(repoURL: URL, repoID: String) {
        stubFile(repoURL: repoURL, repoID: repoID, relativePath: "model_index.json",
                 data: Data(sd21ManifestJSON().utf8))
        for module in ["unet", "vae", "text_encoder"] {
            stubFile(repoURL: repoURL, repoID: repoID, relativePath: "\(module)/config.json",
                     data: Data(#"{"sample_size": 64}"#.utf8))
        }
        for (module, weights) in [
            ("unet", "diffusion_pytorch_model.safetensors"),
            ("vae", "diffusion_pytorch_model.safetensors"),
            ("text_encoder", "model.safetensors"),
        ] {
            stubFile(repoURL: repoURL, repoID: repoID, relativePath: "\(module)/\(weights)",
                     data: makeSafetensorsBlob())
        }
        stubFile(repoURL: repoURL, repoID: repoID, relativePath: "tokenizer/vocab.json",
                 data: Data(#"{"hello": 0}"#.utf8))
        stubFile(repoURL: repoURL, repoID: repoID, relativePath: "tokenizer/merges.txt",
                 data: Data("#version: 0.2\na b\n".utf8))
        stubFile(repoURL: repoURL, repoID: repoID, relativePath: "scheduler/scheduler_config.json",
                 data: Data(#"{"beta_start": 0.00085}"#.utf8))
    }

    /// The service's `downloadURL` always builds against `huggingface.co`. To
    /// route through `MockURLProtocol` (which keys stubs by absolute URL), we
    /// override the per-test host. This wraps `downloadDiffusionModel` with a
    /// rebound base URL by using URLProtocol stubs registered on the
    /// production host. Easier path: stub against `huggingface.co` directly,
    /// disambiguated per-test by prepending a UUID to every relative path.
    ///
    /// We take that route: the repoID itself is a per-test UUID, so all file
    /// URLs are unique to this test even though they live under
    /// `huggingface.co`.
    func test_sd21_happyPath_downloadsAllFiles() async throws {
        let repoID = "test-org/sd21-\(UUID().uuidString.lowercased())"
        let baseURL = URL(string: "https://huggingface.co")!
        stubSD21Set(repoURL: baseURL, repoID: repoID)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = HuggingFaceService()

        let progressEvents = ProgressRecorder()

        let info = try await service.downloadDiffusionModel(
            from: repoID,
            to: tempDir,
            urlSession: session,
            progress: { progressEvents.record($0) }
        )

        XCTAssertEqual(info.format, .mlxDiffusion)
        XCTAssertEqual(info.huggingFaceRepoID, repoID)
        // Hub layout: snapshot files live at `<root>/models/<org>/<name>/...`
        // (see DiffusionDownload.hubLeafDirectory). `directoryURL` is the
        // Hub leaf so `MLXDiffusionBackend` can derive `HubApi(downloadBase:)`
        // by walking three components up without a symlink bridge.
        let hubLeaf = tempDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoID, isDirectory: true)
        XCTAssertEqual(info.directoryURL, hubLeaf)
        XCTAssertGreaterThan(info.fileSize, 0)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf.appendingPathComponent("model_index.json").path))
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf.appendingPathComponent("unet/config.json").path))
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf
            .appendingPathComponent("unet/diffusion_pytorch_model.safetensors").path))
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf.appendingPathComponent("vae/config.json").path))
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf
            .appendingPathComponent("vae/diffusion_pytorch_model.safetensors").path))
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf.appendingPathComponent("text_encoder/config.json").path))
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf
            .appendingPathComponent("text_encoder/model.safetensors").path))
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf.appendingPathComponent("tokenizer/vocab.json").path))
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf.appendingPathComponent("tokenizer/merges.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf
            .appendingPathComponent("scheduler/scheduler_config.json").path))

        XCTAssertFalse(fm.fileExists(atPath: hubLeaf.appendingPathComponent("text_encoder_2").path))
        XCTAssertFalse(fm.fileExists(atPath: hubLeaf.appendingPathComponent("tokenizer_2").path))

        XCTAssertGreaterThan(progressEvents.count, 0, "Progress callback should fire at least once")
        let finalEvent = progressEvents.last!
        // SD 2.1 plan: unet (2) + vae (2) + text_encoder (2) + tokenizer (2)
        // + scheduler (1) = 9. Manifest is fetched separately.
        XCTAssertEqual(finalEvent.totalFileCount, 9)
    }

    func test_sdxl_happyPath_downloadsBothTextEncoders() async throws {
        let repoID = "test-org/sdxl-\(UUID().uuidString.lowercased())"
        let baseURL = URL(string: "https://huggingface.co")!

        stubFile(repoURL: baseURL, repoID: repoID, relativePath: "model_index.json",
                 data: Data(sdxlManifestJSON().utf8))
        for module in ["unet", "vae", "text_encoder", "text_encoder_2"] {
            stubFile(repoURL: baseURL, repoID: repoID, relativePath: "\(module)/config.json",
                     data: Data(#"{"sample_size": 128}"#.utf8))
        }
        for (module, weights) in [
            ("unet", "diffusion_pytorch_model.safetensors"),
            ("vae", "diffusion_pytorch_model.safetensors"),
            ("text_encoder", "model.safetensors"),
            ("text_encoder_2", "model.safetensors"),
        ] {
            stubFile(repoURL: baseURL, repoID: repoID, relativePath: "\(module)/\(weights)",
                     data: makeSafetensorsBlob())
        }
        for tk in ["tokenizer", "tokenizer_2"] {
            stubFile(repoURL: baseURL, repoID: repoID, relativePath: "\(tk)/vocab.json",
                     data: Data(#"{"a": 0}"#.utf8))
            stubFile(repoURL: baseURL, repoID: repoID, relativePath: "\(tk)/merges.txt",
                     data: Data("#version: 0.2\nx y\n".utf8))
        }
        stubFile(repoURL: baseURL, repoID: repoID, relativePath: "scheduler/scheduler_config.json",
                 data: Data(#"{"beta_end": 0.012}"#.utf8))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = HuggingFaceService()

        let info = try await service.downloadDiffusionModel(
            from: repoID,
            to: tempDir,
            urlSession: session,
            progress: { _ in }
        )

        XCTAssertEqual(info.format, .mlxDiffusion)
        let hubLeaf = tempDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoID, isDirectory: true)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf
            .appendingPathComponent("text_encoder_2/model.safetensors").path))
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf.appendingPathComponent("tokenizer_2/vocab.json").path))
        XCTAssertTrue(fm.fileExists(atPath: hubLeaf.appendingPathComponent("tokenizer_2/merges.txt").path))
    }

    func test_manifestFetchFails_surfacesError() async {
        let repoID = "test-org/missing-\(UUID().uuidString.lowercased())"
        let baseURL = URL(string: "https://huggingface.co")!
        stubFileError(repoURL: baseURL, repoID: repoID, relativePath: "model_index.json", statusCode: 404)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = HuggingFaceService()

        do {
            _ = try await service.downloadDiffusionModel(
                from: repoID, to: tempDir, urlSession: session, progress: { _ in }
            )
            XCTFail("Expected error for 404 manifest")
        } catch {
            // Expected.
        }
    }

    func test_truncatedSafetensors_failsValidation() async {
        let repoID = "test-org/truncated-\(UUID().uuidString.lowercased())"
        let baseURL = URL(string: "https://huggingface.co")!
        stubFile(repoURL: baseURL, repoID: repoID, relativePath: "model_index.json",
                 data: Data(sd21ManifestJSON().utf8))
        for module in ["unet", "vae", "text_encoder"] {
            stubFile(repoURL: baseURL, repoID: repoID, relativePath: "\(module)/config.json",
                     data: Data(#"{"a": 1}"#.utf8))
        }
        // UNet weights claims a header longer than the file — validator must reject.
        var bogus = Data(count: 16)
        let bogusLen: UInt64 = 1_000_000_000
        bogus.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: bogusLen.littleEndian, as: UInt64.self)
        }
        stubFile(repoURL: baseURL, repoID: repoID,
                 relativePath: "unet/diffusion_pytorch_model.safetensors",
                 data: bogus)
        // Other files harmless — they aren't reached because UNet is downloaded first.
        for (module, weights) in [
            ("vae", "diffusion_pytorch_model.safetensors"),
            ("text_encoder", "model.safetensors"),
        ] {
            stubFile(repoURL: baseURL, repoID: repoID, relativePath: "\(module)/\(weights)",
                     data: makeSafetensorsBlob())
        }
        stubFile(repoURL: baseURL, repoID: repoID, relativePath: "tokenizer/vocab.json",
                 data: Data(#"{"a":0}"#.utf8))
        stubFile(repoURL: baseURL, repoID: repoID, relativePath: "tokenizer/merges.txt",
                 data: Data("#version: 0.2\na b\n".utf8))
        stubFile(repoURL: baseURL, repoID: repoID, relativePath: "scheduler/scheduler_config.json",
                 data: Data("{}".utf8))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = HuggingFaceService()

        do {
            _ = try await service.downloadDiffusionModel(
                from: repoID, to: tempDir, urlSession: session, progress: { _ in }
            )
            XCTFail("Expected validation error for truncated safetensors")
        } catch let error as HuggingFaceError {
            switch error {
            case .invalidDownloadedFile:
                break // Expected.
            default:
                XCTFail("Unexpected HuggingFaceError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_pathTraversal_rejectedBeforeDownload() async {
        let repoID = "test-org/evil-\(UUID().uuidString.lowercased())"
        let baseURL = URL(string: "https://huggingface.co")!
        let evilManifest = #"""
        {
          "../../../etc/passwd": ["EvilModel", "evil"],
          "unet": ["UNet2DConditionModel", "unet"]
        }
        """#
        stubFile(repoURL: baseURL, repoID: repoID, relativePath: "model_index.json",
                 data: Data(evilManifest.utf8))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = HuggingFaceService()

        do {
            _ = try await service.downloadDiffusionModel(
                from: repoID, to: tempDir, urlSession: session, progress: { _ in }
            )
            XCTFail("Expected path-traversal rejection")
        } catch let error as HuggingFaceError {
            switch error {
            case .invalidDownloadedFile(let reason):
                XCTAssertTrue(reason.contains("Unsafe") || reason.lowercased().contains("path"),
                              "Reason should mention unsafe path; got: \(reason)")
            default:
                XCTFail("Expected invalidDownloadedFile, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_progressReporting_sumsAcrossFiles() async throws {
        let repoID = "test-org/progress-\(UUID().uuidString.lowercased())"
        let baseURL = URL(string: "https://huggingface.co")!
        stubSD21Set(repoURL: baseURL, repoID: repoID)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = HuggingFaceService()

        let recorder = ProgressRecorder()
        let info = try await service.downloadDiffusionModel(
            from: repoID, to: tempDir, urlSession: session,
            progress: { recorder.record($0) }
        )

        XCTAssertGreaterThan(recorder.count, 0)
        let finalReceived = recorder.last!.totalBytesReceived
        XCTAssertEqual(finalReceived, info.fileSize,
                       "Final progress should match the returned ImageModelInfo.fileSize")
    }
}

// MARK: - ProgressRecorder

/// Thread-safe recorder for `DiffusionDownloadProgress` events. The download
/// helper invokes the progress closure from `URLSession`'s delegate context,
/// so we synchronise reads/writes here rather than relying on the closure's
/// caller threading.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiffusionDownloadProgress] = []

    func record(_ event: DiffusionDownloadProgress) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return events.count
    }

    var last: DiffusionDownloadProgress? {
        lock.lock(); defer { lock.unlock() }
        return events.last
    }
}
