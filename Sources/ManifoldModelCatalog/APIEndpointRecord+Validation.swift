import Foundation
import ManifoldNetworking

extension APIEndpointRecord {

    /// Validates the `baseURL` for structural correctness and SSRF safety.
    ///
    /// Mirrors the policy defined in `APIEndpoint.validate()` (ManifoldCore) so
    /// that the `ManifoldInference` module cannot be bypassed by constructing an
    /// `APIEndpointRecord` directly — e.g. through programmatic injection —
    /// without going through the SwiftData wrapper. Both validators delegate to
    /// ``PrivateIPClassifier`` so the blocked-range rules live in one place.
    ///
    /// For the specific per-reason error description surfaced in UI, use
    /// `APIEndpoint.validate()` and `APIEndpointValidationReason` (ManifoldCore).
    /// This method throws `CloudBackendError.invalidURL` for any rejection so
    /// callers that only need a pass/fail answer do not need to import ManifoldCore.
    package func validate() throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let rawHost = url.host()?.lowercased() else {
            throw CloudBackendError.invalidURL(baseURL)
        }

        guard scheme == "http" || scheme == "https" else {
            throw CloudBackendError.invalidURL(baseURL)
        }

        // Loopback dev servers (e.g. Ollama, LM Studio) are allowed over plain HTTP.
        if PrivateIPClassifier.isLocalhostURL(url) { return }

        // Non-loopback must use HTTPS.
        guard scheme == "https" else {
            throw CloudBackendError.invalidURL(baseURL)
        }

        // Block SSRF pivots into private/link-local/reserved ranges even over HTTPS.
        // Trailing-dot FQDN form resolves identically to the dotless form.
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        if PrivateIPClassifier.classifyIPLiteral(host) != nil {
            throw CloudBackendError.invalidURL(baseURL)
        }
    }
}
