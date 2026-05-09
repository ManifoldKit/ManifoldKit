import Foundation
import ManifoldInference

/// Returns an out-of-distribution fixture timestamp so scenario assertions can
/// distinguish a real tool call from model hallucination.
///
/// The default value — `"2099-01-01T00:00:00Z"` — is intentionally far from any
/// training-data prior so a passing assertion for the literal string is strong
/// evidence the model actually invoked the tool (and quoted its result) rather
/// than inventing a plausible timestamp.
///
/// Override the fixture via the `MANIFOLD_TOOLS_NOW_FIXTURE` environment variable
/// for test variation — useful when a scenario wants to probe a second, distinct
/// nonce to rule out caching artefacts.
public enum NowTool {

    /// Default out-of-distribution fixture timestamp.
    public static let defaultFixture = "2099-01-01T00:00:00Z"

    /// Output shape. A single-field struct keeps the JSON small and
    /// stable: `{ "timestamp": "<iso8601 string>" }`.
    public struct Result: Encodable, Sendable {
        public let timestamp: String
    }

    /// Resolves the fixture to emit. Reads `MANIFOLD_TOOLS_NOW_FIXTURE` once per
    /// call so tests can mutate the env between invocations.
    public static func fixture() -> String {
        ProcessInfo.processInfo.environment["MANIFOLD_TOOLS_NOW_FIXTURE"] ?? defaultFixture
    }

    /// Factory — the empty-args shape is expressed as a decoder that accepts
    /// an empty object (or any object; we ignore arguments entirely).
    public static func makeExecutor() -> TypedToolExecutor<EmptyArgs, Result> {
        let definition = ToolDefinition(
            name: "now",
            description: "Returns the current time as an ISO-8601 timestamp. Call this whenever the user asks about the current time or date; never guess.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ])
        )
        return TypedToolExecutor(definition: definition) { _ in
            Result(timestamp: fixture())
        }
    }
}

/// Empty argument envelope — exposed here so other zero-argument tools can
/// reuse it without re-declaring the pattern.
public struct EmptyArgs: Decodable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {
        // Intentionally permissive: accept both `{}` and `null` without error.
        // Some backends emit `null` for zero-argument tools. We probe the
        // keyed container explicitly so the silent-catch audit doesn't flag
        // a bare `try?` — a `do/catch { }` on a Foundation decoder is the
        // established pattern for shape probes in this codebase.
        do {
            _ = try decoder.container(keyedBy: AnyKey.self)
        } catch {
            // No container → accept anyway. EmptyArgs carries no state.
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
    }
}
