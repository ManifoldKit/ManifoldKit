import XCTest
@testable import ManifoldInference
#if HuggingFace
@testable import ManifoldHuggingFace

/// Hermetic coverage for the fp16-vs-full-precision selection rule.
///
/// We test the pure helpers (`selectVariant`, `fp16Path`,
/// `candidateWeightPaths`) directly rather than the full downloader so the
/// test stays a single-call assertion with no network plumbing — matches
/// what the issue calls out as "test on a fixture of siblings listings".
final class DiffusionFP16DetectionTests: XCTestCase {

    // MARK: - fp16Path mapping

    func test_fp16Path_appendsInfixForSafetensors() {
        XCTAssertEqual(
            HuggingFaceService.fp16Path(for: "unet/diffusion_pytorch_model.safetensors"),
            "unet/diffusion_pytorch_model.fp16.safetensors"
        )
    }

    func test_fp16Path_isIdempotentForAlreadyFP16() {
        XCTAssertEqual(
            HuggingFaceService.fp16Path(for: "unet/diffusion_pytorch_model.fp16.safetensors"),
            "unet/diffusion_pytorch_model.fp16.safetensors"
        )
    }

    func test_fp16Path_leavesNonSafetensorsAlone() {
        XCTAssertEqual(
            HuggingFaceService.fp16Path(for: "tokenizer/vocab.json"),
            "tokenizer/vocab.json"
        )
    }

    // MARK: - selectVariant fixture matrix

    /// (a) Only fp32 weights present → full-precision.
    func test_selectVariant_onlyFullPrecision_picksFullPrecision() {
        let weights = [
            "unet/diffusion_pytorch_model.safetensors",
            "vae/diffusion_pytorch_model.safetensors",
            "text_encoder/model.safetensors",
        ]
        let fp16Available: Set<String> = []
        XCTAssertEqual(
            HuggingFaceService.selectVariant(weightPaths: weights, fp16Available: fp16Available),
            .fullPrecision
        )
    }

    /// (b) Only fp16 siblings advertised → fp16.
    func test_selectVariant_onlyFP16_picksFP16() {
        let weights = [
            "unet/diffusion_pytorch_model.safetensors",
            "vae/diffusion_pytorch_model.safetensors",
        ]
        let fp16Available: Set<String> = [
            "unet/diffusion_pytorch_model.fp16.safetensors",
            "vae/diffusion_pytorch_model.fp16.safetensors",
        ]
        XCTAssertEqual(
            HuggingFaceService.selectVariant(weightPaths: weights, fp16Available: fp16Available),
            .fp16
        )
    }

    /// (c) Both fp32 and fp16 present in the repo's file listing → fp16
    /// (the whole point of the feature — prefer the smaller, faster variant
    /// when the user opts in).
    func test_selectVariant_bothAvailable_picksFP16() {
        let weights = [
            "unet/diffusion_pytorch_model.safetensors",
            "vae/diffusion_pytorch_model.safetensors",
            "text_encoder/model.safetensors",
            "text_encoder_2/model.safetensors",
        ]
        // Simulates `getModel(...).siblings` listing every file; fp16
        // siblings exist alongside their full-precision counterparts.
        let fp16Available: Set<String> = [
            "unet/diffusion_pytorch_model.fp16.safetensors",
            "vae/diffusion_pytorch_model.fp16.safetensors",
            "text_encoder/model.fp16.safetensors",
            "text_encoder_2/model.fp16.safetensors",
        ]
        XCTAssertEqual(
            HuggingFaceService.selectVariant(weightPaths: weights, fp16Available: fp16Available),
            .fp16
        )
    }

    /// (d) Partial fp16 coverage — UNet has an fp16 sibling, VAE doesn't.
    /// We report `.fp16` because the bulk weights (UNet dominates the
    /// package size) save real bytes; downstream consumers need to know
    /// the package isn't pure full-precision so they can label / cache
    /// accordingly. The per-file substitution is what actually decides
    /// disk usage; this overall flag is just a hint.
    func test_selectVariant_partialFP16_picksFP16() {
        let weights = [
            "unet/diffusion_pytorch_model.safetensors",
            "vae/diffusion_pytorch_model.safetensors",
            "text_encoder/model.safetensors",
        ]
        let fp16Available: Set<String> = [
            "unet/diffusion_pytorch_model.fp16.safetensors",
            // VAE + text encoder fp16 not in the repo.
        ]
        XCTAssertEqual(
            HuggingFaceService.selectVariant(weightPaths: weights, fp16Available: fp16Available),
            .fp16
        )
    }

    // MARK: - candidateWeightPaths

    /// SD-style manifests (unet + vae + single text encoder) produce the
    /// expected candidate list, in submodule order.
    func test_candidateWeightPaths_sdManifest() {
        let manifest = HuggingFaceService.DiffusionManifest(
            submodules: ["unet", "vae", "text_encoder", "tokenizer", "scheduler"]
        )
        XCTAssertEqual(
            HuggingFaceService.candidateWeightPaths(for: manifest),
            [
                "unet/diffusion_pytorch_model.safetensors",
                "vae/diffusion_pytorch_model.safetensors",
                "text_encoder/model.safetensors",
            ]
        )
    }

    /// SDXL manifests bring `text_encoder_2`; FLUX manifests use
    /// `transformer` in place of `unet`. The candidate list must cover
    /// both shapes so fp16 detection works for FLUX too.
    func test_candidateWeightPaths_sdxlAndFlux() {
        let sdxl = HuggingFaceService.DiffusionManifest(
            submodules: ["unet", "vae", "text_encoder", "text_encoder_2", "tokenizer", "tokenizer_2", "scheduler"]
        )
        XCTAssertEqual(Set(HuggingFaceService.candidateWeightPaths(for: sdxl)), Set([
            "unet/diffusion_pytorch_model.safetensors",
            "vae/diffusion_pytorch_model.safetensors",
            "text_encoder/model.safetensors",
            "text_encoder_2/model.safetensors",
        ]))

        let flux = HuggingFaceService.DiffusionManifest(
            submodules: ["transformer", "vae", "text_encoder", "tokenizer", "scheduler"]
        )
        XCTAssertEqual(Set(HuggingFaceService.candidateWeightPaths(for: flux)), Set([
            "transformer/diffusion_pytorch_model.safetensors",
            "vae/diffusion_pytorch_model.safetensors",
            "text_encoder/model.safetensors",
        ]))
    }
}
#endif
