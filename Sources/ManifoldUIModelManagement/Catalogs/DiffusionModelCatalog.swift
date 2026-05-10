import Foundation

/// One curated entry in the diffusion-model install catalog.
///
/// Sibling to the curated text-model list — kept narrow on purpose so the
/// first-run image install flow has obvious good defaults without inviting a
/// general-purpose browser. Hosts that want a different list can ignore the
/// catalog and call ``HuggingFaceService/downloadDiffusionModel(from:to:displayName:urlSession:progress:)``
/// directly.
public struct DiffusionModelCatalogEntry: Sendable, Identifiable, Hashable {
    /// Stable identifier — the HuggingFace repo ID
    /// (e.g. `"stabilityai/sdxl-turbo"`). Matches `id` on the resulting
    /// ``ImageModelInfo``.
    public let id: String

    /// Human-readable display name (e.g. `"SDXL Turbo"`).
    public let displayName: String

    /// One- or two-sentence description of what the model is good at and any
    /// memory-class caveats. Rendered next to the install button.
    public let description: String

    /// Estimated total bytes the model will occupy on disk after download.
    /// Used for the install button label and a soft disk-space heads-up; the
    /// real size is whatever the manifest resolves to.
    public let approximateBytes: Int64

    public init(
        id: String,
        displayName: String,
        description: String,
        approximateBytes: Int64
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.approximateBytes = approximateBytes
    }

    /// Human-readable size (e.g. `"4.2 GB"`).
    public var approximateSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
    }
}

/// Curated list of known-good diffusion models for the first-run install flow.
///
/// Intentionally narrow. Adding more entries is mechanical — a follow-up PR
/// can broaden this without re-architecting. Pure data, deliberately not
/// `@MainActor` so it's usable from any context.
public enum DiffusionModelCatalog {
    public static let curated: [DiffusionModelCatalogEntry] = [
        DiffusionModelCatalogEntry(
            id: "argmaxinc/mlx-FLUX.1-schnell-4bit-quantized",
            displayName: "FLUX.1 Schnell",
            description: "High-quality 1024×1024 generation in 4 steps. Apache 2.0 licensed. Requires an M-series Mac.",
            approximateBytes: 7_030_000_000
        ),
    ]
}
