import Foundation

/// Actionable error returned when discovering or loading a local model file fails.
///
/// `ModelDiscoveryError` replaces the previous "silent `nil`" return from
/// `ModelInfo(ggufURL:)` for callers that want to surface *why* a file did not
/// turn into a `ModelInfo`. The UI uses this to swap a cryptic
/// "low-level GGUF metadata read failure" log line for a message a user can act
/// on ("file is missing", "file is not a GGUF", etc.) — see #1468.
public enum ModelDiscoveryError: LocalizedError, Equatable, Sendable {
    /// The path passed to the loader does not exist on disk.
    case fileMissing(path: String)
    /// The file exists but cannot be opened for reading (sandbox / permissions /
    /// data protection). Path is included so the UI can suggest dragging the
    /// file into the app's window or checking entitlements.
    case notReadable(path: String, reason: String)
    /// The file exists and is readable but does not carry the GGUF magic bytes
    /// at offset 0. Likely a renamed non-GGUF file, a truncated download, or a
    /// placeholder stub.
    case notGGUF(path: String)
    /// The file is a valid GGUF (magic bytes present) but the header metadata
    /// section failed to parse. Surfaces the underlying reader error so logs
    /// can carry it without leaking it as the user-facing message.
    case metadataReadFailed(path: String, underlying: String)
    /// The path resolves to an unexpected file kind (e.g. a directory passed
    /// where a `.gguf` was expected). Kept separate from `fileMissing` so the
    /// UI can offer different guidance.
    case unexpectedFileKind(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let path):
            return "Model file not found at \(path)."
        case .notReadable(let path, let reason):
            return "Model file at \(path) exists but cannot be read (\(reason)). On iOS this often means the file is under data protection or the app does not have a security-scoped bookmark for it — try importing the file into the app's models directory."
        case .notGGUF(let path):
            return "File at \(path) is not a valid GGUF — the first four bytes did not match the GGUF magic. The file may be a renamed non-GGUF, a truncated download, or a placeholder stub."
        case .metadataReadFailed(_, let underlying):
            return "Could not read GGUF header metadata: \(underlying). The file is a GGUF but its header could not be parsed; prompt template detection will be unavailable."
        case .unexpectedFileKind(let path, let detail):
            return "Unexpected file kind at \(path): \(detail)."
        }
    }

    /// The path the loader was attempting to use, for log + UI surfaces.
    public var path: String {
        switch self {
        case .fileMissing(let path),
             .notReadable(let path, _),
             .notGGUF(let path),
             .metadataReadFailed(let path, _),
             .unexpectedFileKind(let path, _):
            return path
        }
    }
}
