import Foundation
import os

/// Recursively converts a JSONSchemaValue tree into a Foundation-compatible
/// object graph (String, Int, Double, Bool, [String: Any], [Any], or NSNull).
///
/// Returns `nil` if encoding fails — callers are expected to substitute a
/// conservative default (typically an empty-properties object schema).
package func encodeJSONSchemaToFoundation(_ value: JSONSchemaValue) -> Any? {
    let data: Data
    do {
        data = try JSONEncoder().encode(value)
    } catch {
        Log.inference.warning(
            "encodeJSONSchemaToFoundation: failed to encode JSONSchemaValue — substituting empty object. error=\(error.localizedDescription, privacy: .public)"
        )
        return nil
    }
    do {
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
        Log.inference.warning(
            "encodeJSONSchemaToFoundation: failed to re-parse encoded schema — substituting empty object. error=\(error.localizedDescription, privacy: .public)"
        )
        return nil
    }
}
