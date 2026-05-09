#if HuggingFace
import Foundation
import ManifoldInference

internal enum DiffusionPackageValidator {
    internal static func validatePackageName(_ packageName: String) throws {
        guard !packageName.isEmpty,
              packageName.count < 255,
              !packageName.contains("/"),
              !packageName.contains("\\"),
              packageName != ".",
              packageName != "..",
              !packageName.hasPrefix(".") else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Invalid package directory name: \(packageName)")
        }
        guard packageName.unicodeScalars.allSatisfy({ scalar in
            let v = scalar.value
            return v >= 0x20 && v != 0x7F && !(0x80...0x9F).contains(v)
        }) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Package directory name contains control characters")
        }
    }

    internal static func validateComponent(at url: URL, relativePath: String) throws {
        guard let role = diffusionRole(for: relativePath) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Unsupported diffusion package component: \(relativePath)")
        }
        try DownloadFileValidator.validate(url, diffusionRole: role)
    }

    internal static func validatePackage(at directory: URL, files: [String]) throws {
        let fileSet = Set(files)
        for required in [
            "model_index.json",
            "vae/config.json",
            "vae/diffusion_pytorch_model.safetensors",
        ] where !fileSet.contains(required) {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Diffusion package is missing required component: \(required)")
        }
        let hasDenoiser = fileSet.contains("unet/diffusion_pytorch_model.safetensors")
            || fileSet.contains("transformer/diffusion_pytorch_model.safetensors")
            || fileSet.contains("transformer/model.safetensors")
        guard hasDenoiser else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Diffusion package is missing transformer/UNet weights")
        }
        for relativePath in files {
            try validateComponent(at: directory.appendingPathComponent(relativePath), relativePath: relativePath)
        }
    }

    internal static func diffusionRole(for relativePath: String) -> DownloadFileValidator.DiffusionFileRole? {
        switch relativePath {
        case "model_index.json":
            return .manifest
        case let path where path.hasSuffix("/config.json") || path.hasSuffix("/scheduler_config.json"):
            return .submoduleConfig
        case let path where path.hasSuffix(".safetensors"):
            return .weights
        case let path where path.hasSuffix("/vocab.json"):
            return .tokenizerVocab
        case let path where path.hasSuffix("/merges.txt"):
            return .tokenizerMerges
        default:
            return nil
        }
    }

    internal static func writePackageManifest(
        for model: DownloadableModel,
        files: [String],
        in directory: URL
    ) throws {
        let manifest = DownloadedModelPackageManifest(
            packageKind: .diffusion,
            id: model.repoID,
            displayName: model.displayName,
            format: .mlxDiffusion,
            huggingFaceRepoID: model.repoID,
            files: files.sorted()
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: directory.appendingPathComponent(DownloadedModelPackageManifest.fileName),
            options: .atomic
        )
    }
}
#endif
