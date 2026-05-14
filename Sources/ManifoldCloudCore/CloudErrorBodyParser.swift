import Foundation

/// Extracts a human-readable error message from a JSON error response body.
///
/// Returns nil if the body is not parseable JSON or contains no recognized message field.
/// The `try?` here is intentional — JSON parse failure means we return nil and the caller
/// falls back to a generic error message. This is not an error-propagation path.
package func parseCloudErrorMessage(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    // OpenAI/Anthropic style: { "error": { "message": "..." } }
    if let error = json["error"] as? [String: Any],
       let message = error["message"] as? String, !message.isEmpty {
        return message
    }
    // Flat: { "message": "..." }
    if let message = json["message"] as? String, !message.isEmpty {
        return message
    }
    // detail field (some APIs)
    if let detail = json["detail"] as? String, !detail.isEmpty {
        return detail
    }
    return nil
}

/// Overload for callers that have the body as a String already.
package func parseCloudErrorMessage(from string: String) -> String? {
    guard let data = string.data(using: .utf8) else { return nil }
    return parseCloudErrorMessage(from: data)
}
