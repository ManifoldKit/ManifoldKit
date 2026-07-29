import Foundation
import ManifoldInference

/// A fixed, ordered pool of plausible-but-irrelevant "decoy" tool definitions
/// used to raise the bar on tool-*selection* scoring: `ScenarioRunner`
/// normally advertises only a scenario's `requiredTools`, so a passing run
/// can't distinguish "the model picked the right tool" from "the model had no
/// other tool to pick." Padding the advertised toolset with decoys via
/// `--extra-tools N` (parsed by ``ScenarioCLIHarness/parseCommonFlags(_:defaultOutput:)``)
/// makes a decoy invocation an unambiguous wrong-tool selection.
///
/// **Fixed order, no RNG.** `take(_:)` always returns the first `n` entries of
/// the same list — runs must be reproducible and diffable across CI
/// invocations and across the tool-calling companion CLIs that consume this
/// pool, matching the harness's deterministic-replay contract. Do not
/// reorder existing entries; append new ones at the end so an existing
/// `--extra-tools N` invocation keeps advertising the same names run to run.
///
/// **Consumers.** This was originally three near-identical, hand-maintained
/// copies that had already drifted: an inline catalogue in this repo's own
/// `manifold-tools` executable, and separate `DecoyTools` types in the
/// `manifold-mlx` and `manifold-llama` companion repos' `manifold-tools-mlx`
/// / `manifold-tools-llama` executables. This type is the merged union of all
/// three (the better-specified schema kept per overlapping entry), published
/// from the `ManifoldTools` library so every consumer — this repo's own CLI
/// and, from their next adoption pass, the companions — can delete their
/// local copy and depend on one deterministic pool. See
/// `docs/COMPANION-BACKENDS.md` for the companion-package relationship.
///
/// Names are deliberately drawn from domains orthogonal to BOTH the six
/// reference tools (`now`, `calc`, `read_file`, `list_dir`,
/// `sample_repo_search`, `http_get_fixture`) AND the shipped, model-facing
/// tools defined elsewhere under `Sources/` — e.g. `search_web`
/// (`ManifoldUI/Tools/WebSearchToolSource.swift`) and `invoke_skill`
/// (`ManifoldSkills/SkillToolSource.swift`) — so a decoy call is never a
/// defensible substitution for a built-in scenario's real tool, and padding
/// a toolset that already contains one of those shipped tools via
/// `--extra-tools N` never advertises the same name twice. See
/// `ToolNameCollisionAuditTest` for the enforcement.
public enum DecoyTools {

    /// Largest `--extra-tools N` this pool can satisfy without repeating a
    /// name.
    public static var maxCount: Int { pool.count }

    /// Result shape every decoy executor returns. Content is inert and
    /// clearly marked — decoys exist to be *advertised*, not dispatched; if a
    /// model wrongly calls one, this keeps the run alive with a benign,
    /// greppable payload in the transcript instead of an error.
    public struct Result: Encodable, Sendable {
        public let note: String
    }

    /// The first `n` decoy definitions, in fixed pool order (clamped to
    /// `[0, maxCount]`).
    public static func take(_ n: Int) -> [ToolDefinition] {
        Array(pool.prefix(max(0, n)))
    }

    /// Names of the first `n` decoys, in pool order. Convenience for callers
    /// that only need to pad a scenario's `requiredTools` set (`ScenarioRunner`
    /// advertises exactly the tools named there).
    public static func names(_ n: Int) -> [String] {
        take(n).map(\.name)
    }

    /// Ready-to-register no-op executors for the first `n` decoys. Each
    /// accepts any arguments and returns a fixed marker so a wrong-tool
    /// dispatch is visible in the transcript without crashing the run.
    ///
    /// Decoys are stateless, so they opt into concurrent batch dispatch —
    /// registering one must never force an otherwise-parallel multi-call
    /// round into sequential dispatch (`TypedToolExecutor` cannot express
    /// this; it inherits the protocol's `false` default, hence the bespoke
    /// executor type).
    public static func executors(_ n: Int) -> [any ToolExecutor] {
        take(n).map { DecoyExecutor(definition: $0) }
    }

    /// Inert executor for one decoy definition. Ignores its arguments —
    /// decoys exist to be advertised, never legitimately dispatched.
    private struct DecoyExecutor: ToolExecutor {
        let definition: ToolDefinition
        var supportsConcurrentDispatch: Bool { true }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            let payload = Result(note: "decoy tool '\(definition.name)' is not the right tool for this task")
            let data = try JSONEncoder().encode(payload)
            let content = String(data: data, encoding: .utf8) ?? ""
            return ToolResult(callId: "", content: content, errorKind: nil)
        }
    }

    /// Helper to build a JSON-Schema object with string-typed properties —
    /// decoys are never really dispatched, so an all-string schema keeps the
    /// pool declaration compact without weakening distractor pressure (the
    /// model only ever sees name, description, and parameter names).
    private static func obj(_ props: [(String, String)], required: [String]) -> JSONSchemaValue {
        var properties: [String: JSONSchemaValue] = [:]
        for (name, desc) in props {
            properties[name] = .object([
                "type": .string("string"),
                "description": .string(desc)
            ])
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONSchemaValue.string))
        ])
    }

    private static func def(_ name: String, _ description: String, _ props: [(String, String)], required: [String]) -> ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: obj(props, required: required))
    }

    /// The ordered decoy pool — union of the three previously-drifted copies
    /// (this repo's `manifold-tools`, and `manifold-tools-mlx` /
    /// `manifold-tools-llama` in the companion repos), deduplicated by
    /// concept and kept in a fixed order. 46 entries so `--extra-tools` can
    /// pad well past any scenario sweep in use today (max observed: 20).
    private static let pool: [ToolDefinition] = [
        def("get_weather", "Returns the current weather conditions for a city.",
            [("city", "City name, e.g. 'San Francisco'."), ("units", "'metric' or 'imperial'.")], required: ["city"]),
        def("send_email", "Sends an email to a recipient with a subject and body.",
            [("to", "Recipient address"), ("subject", "Subject line"), ("body", "Email body")], required: ["to", "body"]),
        def("get_movie_showtimes", "Returns movie showtimes for a theater or area.",
            [("movie", "Movie title"), ("location", "Theater or area name")], required: ["movie"]),
        def("translate_text", "Translates text into a target language.",
            [("text", "Text to translate"), ("target_language", "Target language code")], required: ["text", "target_language"]),
        def("set_timer", "Starts a countdown timer for the given duration.",
            [("duration", "Duration, e.g. '10 minutes'")], required: ["duration"]),
        def("convert_currency", "Converts an amount between two currencies at the current exchange rate.",
            [("amount", "Amount to convert"), ("from", "Source currency code"), ("to", "Target currency code")], required: ["amount", "from", "to"]),
        def("create_calendar_event", "Creates a calendar event with a title, start time, and end time.",
            [("title", "Event title"), ("start", "Start time"), ("end", "End time")], required: ["title", "start"]),
        def("get_stock_price", "Returns the latest trading price for a stock ticker.",
            [("ticker", "Stock ticker symbol")], required: ["ticker"]),
        def("roll_dice", "Rolls dice and returns the total.",
            [("notation", "Dice notation, e.g. '2d6'")], required: ["notation"]),
        def("convert_units", "Converts a value between measurement units.",
            [("value", "Numeric value"), ("from_unit", "Source unit"), ("to_unit", "Target unit")], required: ["value", "from_unit", "to_unit"]),
        def("send_sms", "Sends a text message to a phone number.",
            [("phone", "Destination phone number"), ("message", "Message text")], required: ["phone", "message"]),
        def("get_directions", "Returns driving directions between two places.",
            [("origin", "Starting location"), ("destination", "Ending location")], required: ["origin", "destination"]),
        def("play_music", "Plays a track from the user's music library.",
            [("track", "Track name"), ("artist", "Artist name")], required: ["track"]),
        def("set_reminder", "Creates a reminder at a given time.",
            [("text", "Reminder text"), ("time", "When to remind")], required: ["text", "time"]),
        def("get_news_headlines", "Returns recent news headlines for a topic.",
            [("topic", "News topic or category")], required: ["topic"]),
        def("book_flight", "Searches and books a flight.",
            [("origin", "Departure airport"), ("destination", "Arrival airport"), ("date", "Travel date")], required: ["origin", "destination", "date"]),
        def("get_definition", "Returns the dictionary definition of a word.",
            [("word", "Word to define")], required: ["word"]),
        def("create_note", "Saves a note to the user's notebook.",
            [("title", "Note title"), ("content", "Note body")], required: ["content"]),
        def("get_traffic", "Returns current traffic conditions for a route.",
            [("route", "Route or area name")], required: ["route"]),
        def("shorten_url", "Creates a shortened URL.",
            [("url", "URL to shorten")], required: ["url"]),
        def("get_recipe", "Returns a recipe for a dish.",
            [("dish", "Dish name")], required: ["dish"]),
        def("track_package", "Returns the delivery status of a package.",
            [("tracking_number", "Carrier tracking number")], required: ["tracking_number"]),
        def("get_horoscope", "Returns the daily horoscope for a star sign.",
            [("sign", "Zodiac sign")], required: ["sign"]),
        def("convert_timezone", "Converts a time between two time zones.",
            [("time", "Time to convert"), ("from_zone", "Source time zone"), ("to_zone", "Target time zone")], required: ["time", "from_zone", "to_zone"]),
        def("post_social_update", "Posts a status update to the user's social account.",
            [("message", "Status text")], required: ["message"]),
        def("control_smart_light", "Turns a smart light on or off in a given room.",
            [("room", "Room name"), ("state", "'on' or 'off'")], required: ["room", "state"]),
        def("order_food", "Places a food delivery order from a restaurant.",
            [("restaurant", "Restaurant name"), ("items", "Comma-separated items")], required: ["restaurant", "items"]),
        def("start_workout", "Starts tracking a workout session.",
            [("type", "Workout type, e.g. 'run'"), ("duration", "Planned duration in minutes")], required: ["type"]),
        def("scan_qr_code", "Decodes a QR code from an image.",
            [("image", "Path or identifier of the image")], required: ["image"]),
        def("set_thermostat", "Sets the home thermostat to a target temperature.",
            [("temperature", "Target temperature in degrees")], required: ["temperature"]),
        def("find_parking", "Finds available parking near a location.",
            [("location", "Location to search near")], required: ["location"]),
        def("get_sunrise_sunset", "Returns sunrise and sunset times for a location and date.",
            [("location", "Location name"), ("date", "Date in YYYY-MM-DD")], required: ["location", "date"]),
        def("summarise_url", "Downloads and summarises the text content at the given URL.",
            [("url", "The URL of the page to summarise")], required: ["url"]),
        def("run_sql_query", "Executes a read-only SQL SELECT statement against the configured analytics database.",
            [("query", "The SQL SELECT statement to run")], required: ["query"]),
        def("get_exchange_rate", "Returns the current exchange rate between two ISO 4217 currency codes.",
            [("from_currency", "Source currency code, e.g. USD"), ("to_currency", "Target currency code")], required: ["from_currency", "to_currency"]),
        def("resize_image", "Resizes an image file to the specified dimensions and returns the path to the resized file.",
            [("path", "Path to the source image file"), ("width", "Target width in pixels"), ("height", "Target height in pixels")], required: ["path"]),
        def("check_dns", "Performs a DNS lookup for a hostname and returns the resolved IP addresses.",
            [("hostname", "The hostname to resolve")], required: ["hostname"]),
        def("fetch_git_log", "Returns the most recent commits from a git repository at the given path.",
            [("repo_path", "Path to the git repository")], required: ["repo_path"]),
        def("list_s3_objects", "Lists objects in an S3 bucket with an optional key prefix filter.",
            [("bucket", "S3 bucket name"), ("prefix", "Optional key prefix filter")], required: ["bucket"]),
        def("ping_host", "Sends ICMP echo requests to a host and returns round-trip latency statistics.",
            [("host", "Hostname or IP address to ping")], required: ["host"]),
        def("parse_csv", "Parses a CSV file and returns the first N rows as a JSON array.",
            [("path", "Path to the CSV file"), ("rows", "Number of rows to return")], required: ["path"]),
        def("hash_file", "Computes the SHA-256 hash of a file and returns it as a hex string.",
            [("path", "Path to the file to hash")], required: ["path"]),
        def("get_system_uptime", "Returns the current system uptime in human-readable format.",
            [("format", "Output format: 'human' or 'seconds'")], required: []),
        def("fetch_rss_feed", "Fetches an RSS feed from the given URL and returns the latest items.",
            [("url", "URL of the RSS feed"), ("limit", "Maximum number of items to return")], required: ["url"]),
        def("diff_files", "Computes a unified diff between two text files.",
            [("file_a", "Path to the first file"), ("file_b", "Path to the second file")], required: ["file_a", "file_b"]),
        def("validate_json", "Validates a JSON string against an optional JSON Schema and returns a pass/fail result.",
            [("json", "The JSON string to validate"), ("schema", "Optional JSON Schema to validate against")], required: ["json"]),
    ]
}
