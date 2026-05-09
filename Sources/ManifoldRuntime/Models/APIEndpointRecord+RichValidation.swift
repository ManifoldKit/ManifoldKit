import Foundation
import ManifoldInference

extension APIEndpointRecord {

    /// Rich validation that returns the specific ``APIEndpointValidationReason``
    /// when an endpoint URL is rejected, mirroring `APIEndpoint.validate()`.
    ///
    /// Both forms delegate to ``PrivateIPClassifier`` so the blocked-range
    /// rules live in one place. Use this overload when the UI needs to surface
    /// *why* an endpoint is rejected; use ``validate()`` (the throwing form on
    /// `ManifoldInference`) when a pass/fail answer is sufficient.
    public func validateBaseURL() -> Result<Void, APIEndpointValidationReason> {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(.emptyURL)
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              url.host() != nil else {
            return .failure(.malformedURL)
        }

        guard scheme == "http" || scheme == "https" else {
            return .failure(.unsupportedScheme(scheme))
        }

        if PrivateIPClassifier.isLocalhostURL(url) {
            return .success(())
        }

        if scheme != "https" {
            return .failure(.insecureScheme)
        }

        if let reason = Self.classifyDisallowedPrivateHost(url) {
            return .failure(reason)
        }

        return .success(())
    }

    /// `true` when ``validateBaseURL()`` returns `.success`.
    public var isValid: Bool {
        if case .success = validateBaseURL() { return true }
        return false
    }

    private static func classifyDisallowedPrivateHost(_ url: URL) -> APIEndpointValidationReason? {
        guard let rawHost = url.host()?.lowercased() else { return nil }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost

        guard let category = PrivateIPClassifier.classifyIPLiteral(host) else {
            return nil
        }

        switch category {
        case .privateHost:        return .privateHost
        case .linkLocalHost:      return .linkLocalHost
        case .ipv6UniqueLocal:    return .ipv6UniqueLocal
        case .ipv4MappedLoopback: return .ipv4MappedLoopback
        case .multicastReserved:  return .multicastReserved
        }
    }
}
