import Foundation

/// Per-file, warn-only sidecar recording the SHA-256 of a single-file model's
/// embedded chat template, captured on first observation for drift detection
/// (#1932).
///
/// **Deliberately distinct from `GGUFSignedManifest` / `<file>.manifest.json`.**
/// That manifest hashes the model's *weight bytes* and its verifier *throws* on
/// mismatch — a digest mismatch there means tampering and must fail closed.
/// Chat-template drift is a softer signal: a template that changed underneath a
/// cached selection should only *warn* and let the load proceed. Keeping a
/// separate record (and a separate filename) ensures the two semantics can never
/// be conflated into one verifier.
///
/// The record is keyed to the model's own filename (see ``sidecarURL(forModelAt:)``),
/// not the shared models directory, so several `.gguf` files living in one
/// directory cannot collide on a single sidecar.
package struct ChatTemplateIntegritySidecar: Codable, Hashable, Sendable {
    /// Filename suffix appended to a model's path to locate its sidecar
    /// (`foo.gguf` → `foo.gguf.template.json`).
    package static let fileNameSuffix = ".template.json"

    /// SHA-256 (lowercase hex) of the model's embedded chat template, captured
    /// the first time the model was loaded. Compared against the freshly-loaded
    /// template's digest on every subsequent load.
    package let chatTemplateSHA256: String

    package init(chatTemplateSHA256: String) {
        self.chatTemplateSHA256 = chatTemplateSHA256
    }

    /// The sidecar location for a single-file model at `modelURL`: the model's
    /// own filename with ``fileNameSuffix`` appended, in the same directory.
    package static func sidecarURL(forModelAt modelURL: URL) -> URL {
        modelURL
            .deletingLastPathComponent()
            .appendingPathComponent(modelURL.lastPathComponent + fileNameSuffix)
    }
}
