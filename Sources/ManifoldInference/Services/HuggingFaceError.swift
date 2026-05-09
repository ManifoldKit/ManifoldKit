import Foundation

/// Errors that can occur when interacting with the HuggingFace Hub API or downloading models.
public enum HuggingFaceError: LocalizedError {
    /// The search API call failed.
    case searchFailed(underlying: Error)
    /// The specified repository was not found on HuggingFace.
    case modelNotFound(repoID: String)
    /// A file download failed.
    case downloadFailed(underlying: Error)
    /// No network connection is available.
    case networkUnavailable
    /// Not enough free disk space to download the model.
    case insufficientDiskSpace(required: UInt64, available: UInt64)
    /// The downloaded file failed validation (e.g., bad magic bytes).
    case invalidDownloadedFile(reason: String)
    /// The repo ID string could not be parsed as "namespace/name".
    case invalidRepoID(String)

    public var errorDescription: String? {
        switch self {
        case .searchFailed(let underlying):
            return "HuggingFace search failed: \(underlying.localizedDescription)"
        case .modelNotFound(let repoID):
            return "Model not found on HuggingFace: \(repoID)"
        case .downloadFailed(let underlying):
            return "Download failed: \(underlying.localizedDescription)"
        case .networkUnavailable:
            return "No network connection available. Please check your internet connection."
        case .insufficientDiskSpace(let required, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let requiredStr = formatter.string(fromByteCount: Int64(required))
            let availableStr = formatter.string(fromByteCount: Int64(available))
            return "Not enough disk space. Requires \(requiredStr) but only \(availableStr) available."
        case .invalidDownloadedFile(let reason):
            return "Downloaded file is invalid: \(reason)"
        case .invalidRepoID(let id):
            return "Invalid HuggingFace repository ID: \"\(id)\". Expected format: \"namespace/name\"."
        }
    }
}
