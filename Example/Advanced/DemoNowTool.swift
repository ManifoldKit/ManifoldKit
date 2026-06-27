import Foundation
import ManifoldInference

/// Demo-local replacement for ``NowTool`` that returns the real current time.
///
/// The shared reference tool intentionally returns a fixed fixture timestamp so
/// end-to-end tests can distinguish a real tool call from hallucinated output.
/// The demo app should feel live instead, so it uses this executor.
enum DemoNowTool {

    struct Args: Decodable, Sendable {
        let timezone: String?
    }

    struct Result: Encodable, Sendable {
        let timestamp: String
        let timezone: String
        let localTime: String
    }

    /// Raised when the caller passes a `timezone` we can't resolve to a real
    /// zone. We surface it instead of silently falling back to the device's
    /// local zone — a small on-device model routinely passes a bare city name
    /// like `"Tokyo"` (which `TimeZone(identifier:)` rejects), and a silent
    /// fallback would answer with *local* time mislabelled as the requested
    /// place. Throwing feeds the hint back to the model so it can retry with a
    /// proper IANA identifier. See `ToolExecutor` — a thrown error becomes a
    /// tool-error result the model sees.
    struct UnknownTimeZoneError: LocalizedError {
        let requested: String
        var errorDescription: String? {
            "Unknown timezone '\(requested)'. Pass an IANA identifier such as 'Asia/Tokyo', 'Europe/London', or 'America/New_York'."
        }
    }

    /// Best-effort map from a bare city/region name to its IANA identifier, for
    /// the common case where the model passes `"Tokyo"` rather than
    /// `"Asia/Tokyo"`. Not exhaustive — unknown names throw rather than guess.
    static let cityToIANA: [String: String] = [
        "tokyo": "Asia/Tokyo",
        "london": "Europe/London",
        "paris": "Europe/Paris",
        "berlin": "Europe/Berlin",
        "madrid": "Europe/Madrid",
        "rome": "Europe/Rome",
        "moscow": "Europe/Moscow",
        "dubai": "Asia/Dubai",
        "mumbai": "Asia/Kolkata",
        "delhi": "Asia/Kolkata",
        "new delhi": "Asia/Kolkata",
        "singapore": "Asia/Singapore",
        "hong kong": "Asia/Hong_Kong",
        "shanghai": "Asia/Shanghai",
        "beijing": "Asia/Shanghai",
        "seoul": "Asia/Seoul",
        "sydney": "Australia/Sydney",
        "melbourne": "Australia/Melbourne",
        "auckland": "Pacific/Auckland",
        "new york": "America/New_York",
        "nyc": "America/New_York",
        "chicago": "America/Chicago",
        "denver": "America/Denver",
        "los angeles": "America/Los_Angeles",
        "la": "America/Los_Angeles",
        "san francisco": "America/Los_Angeles",
        "sf": "America/Los_Angeles",
        "toronto": "America/Toronto",
        "sao paulo": "America/Sao_Paulo",
        "são paulo": "America/Sao_Paulo",
        "utc": "UTC",
        "gmt": "GMT"
    ]

    /// Resolve a caller-supplied string to a real `TimeZone`, trying in order:
    /// IANA identifier (`Asia/Tokyo`, `GMT+9`), abbreviation (`JST`, `PST`),
    /// then the common-city map. Throws ``UnknownTimeZoneError`` if all fail —
    /// never silently substitutes the local zone.
    static func resolveTimeZone(_ raw: String) throws -> TimeZone {
        if let zone = TimeZone(identifier: raw) {
            return zone
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let zone = TimeZone(abbreviation: trimmed.uppercased()) {
            return zone
        }
        if let iana = cityToIANA[trimmed.lowercased()], let zone = TimeZone(identifier: iana) {
            return zone
        }
        throw UnknownTimeZoneError(requested: raw)
    }

    static func makeExecutor() -> TypedToolExecutor<Args, Result> {
        let definition = ToolDefinition(
            name: "now",
            description: "Returns the current date and time. If the user asks for a place-specific time, pass an IANA timezone like 'Asia/Tokyo' when possible; never guess.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "timezone": .object([
                        "type": .string("string"),
                        "description": .string("Optional IANA timezone identifier, for example 'Asia/Tokyo'.")
                    ])
                ]),
                "required": .array([])
            ])
        )

        return TypedToolExecutor(definition: definition) { args in
            // No timezone asked for → device-local. A supplied timezone must
            // resolve to a real zone; an unrecognized one throws rather than
            // silently answering with local time mislabelled as the request.
            let timeZone: TimeZone
            if let requested = args.timezone, !requested.isEmpty {
                timeZone = try resolveTimeZone(requested)
            } else {
                timeZone = .current
            }
            let clock = ISO8601DateFormatter()
            clock.timeZone = timeZone

            let localFormatter = DateFormatter()
            localFormatter.locale = Locale(identifier: "en_US_POSIX")
            localFormatter.timeZone = timeZone
            localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"

            let now = Date()
            return Result(
                timestamp: clock.string(from: now),
                timezone: timeZone.identifier,
                localTime: localFormatter.string(from: now)
            )
        }
    }
}
