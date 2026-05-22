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
            let timeZone = args.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
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
