#if canImport(CoreGraphics) && canImport(ImageIO)
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldOllama

/// True end-to-end vision tests hitting a real local Ollama server with a real
/// multimodal model.
///
/// These perform real inference: a tiny solid-color PNG is generated in code,
/// attached to a user turn via ``OllamaBackend/setStructuredHistory(_:)``
/// (which lifts the bytes onto Ollama's message-level `images: [base64]`
/// field), and the model is asked to describe it. No stubs — real HTTP, real
/// NDJSON streaming, real multimodal inference.
///
/// Skipped automatically when:
/// - No Ollama server is reachable at `localhost:11434`.
/// - No vision-capable model is installed (tries `vl`, `moondream`, `llava`
///   substrings, or honours an explicit `OLLAMA_TEST_MODEL` override).
///
/// The image content is a single unambiguous solid color so the assertion can
/// be tolerant of small-model phrasing: the bar is *non-empty grounded output*,
/// with a best-effort (non-fatal) check that the named color appears.
@MainActor
final class OllamaVisionE2ETests: XCTestCase {

    private var backend: OllamaBackend!
    private var modelName: String!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(
            HardwareRequirements.hasOllamaServer,
            "Ollama server not running at localhost:11434"
        )

        // Prefer an explicit override, then the common vision-model name
        // substrings in descending availability order on typical dev boxes.
        let candidates = ["vl", "moondream", "llava"]
        var resolved: String?
        for substring in candidates {
            if let match = HardwareRequirements.findOllamaModel(nameContains: substring) {
                resolved = match
                break
            }
        }
        guard let model = resolved else {
            let installed = HardwareRequirements.listOllamaModels()?.joined(separator: ", ") ?? "<none>"
            throw XCTSkip(
                "No vision-capable Ollama model installed (looked for: \(candidates.joined(separator: ", "))). "
                + "Pull e.g. `qwen2.5vl:3b` or `moondream`, or set OLLAMA_TEST_MODEL. Installed: \(installed)"
            )
        }
        modelName = model

        backend = OllamaBackend()
        backend.configure(
            baseURL: URL(string: "http://localhost:11434")!,
            modelName: modelName
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    override func tearDown() async throws {
        backend?.unloadModel()
        backend = nil
        modelName = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Generates a solid-color square PNG entirely in code so the test needs no
    /// binary fixture and the expected answer is unambiguous.
    private func solidColorPNG(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        side: Int = 64
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not create CGContext for test image")
        }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let cgImage = context.makeImage() else {
            throw XCTSkip("Could not render CGImage for test image")
        }

        let pngData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            pngData as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw XCTSkip("Could not create PNG destination for test image")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("Could not finalize PNG for test image")
        }
        return pngData as Data
    }

    /// Sends a structured user turn carrying `imageData` plus `prompt` and
    /// returns the concatenated visible token text.
    private func describe(imageData: Data, prompt: String) async throws -> String {
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text(prompt),
                .image(data: imageData, mimeType: "image/png"),
            ]),
        ])
        let config = GenerationConfig(
            temperature: 0.1,
            maxOutputTokens: 128
        )
        let stream = try backend.generate(
            prompt: prompt,
            systemPrompt: nil,
            config: config
        )
        var text = ""
        for try await event in stream.events {
            if case .token(let t) = event {
                text += t
            }
        }
        return text
    }

    // MARK: - Capability

    /// A loaded vision model must advertise `supportsVision == true` — this is
    /// the bit the `/api/show` probe now surfaces.
    func test_visionModel_advertisesSupportsVision() throws {
        XCTAssertTrue(
            backend.capabilities.supportsVision,
            "Vision model '\(modelName!)' must advertise supportsVision via the /api/show capabilities probe"
        )
        XCTAssertTrue(
            backend.isVisionModel,
            "Vision model '\(modelName!)' must set the probed isVisionModel flag"
        )
    }

    // MARK: - Live Inference

    /// Sends a solid red square and asks the model to describe it. The bar is
    /// non-empty grounded output; a best-effort color-name check is logged but
    /// not fatal, since small models phrase descriptions loosely.
    func test_visionModel_describesSolidColorImage() async throws {
        let red = try solidColorPNG(red: 0.9, green: 0.05, blue: 0.05)
        let text = try await describe(
            imageData: red,
            prompt: "What is the dominant color of this image? Answer in one short sentence."
        )

        XCTAssertFalse(
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Vision model '\(modelName!)' produced no visible output for an image-bearing turn — the images[] wire field is not reaching the model"
        )

        // Best-effort grounding signal — small vision models sometimes say
        // "crimson"/"scarlet"/"maroon" instead of "red", so this is informative
        // only, never the gate.
        let lowered = text.lowercased()
        let redSynonyms = ["red", "crimson", "scarlet", "maroon"]
        if !redSynonyms.contains(where: lowered.contains) {
            print("[OllamaVisionE2E] model '\(modelName!)' did not name a red synonym; raw output: \(text)")
        }
    }
}
#endif
