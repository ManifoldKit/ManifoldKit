import Foundation
import ManifoldInference

/// A `Sendable` JSON value tree.
///
/// Cloud stream extractors historically re-parsed every SSE / NDJSON frame
/// 8–12× — each field extractor independently did `String → Data →
/// JSONSerialization.jsonObject`, and `StreamFinalizer.finalize` re-parsed
/// the same bytes once more. `ParsedFrame` parses each frame **once** and
/// hands the parsed tree to every consumer.
///
/// `[String: Any]` (the natural `JSONSerialization` output) is **not**
/// `Sendable`, so it cannot cross the `AsyncStream`/continuation boundary in
/// the routed stream loop under Swift 6 region isolation. `@unchecked
/// Sendable` is not an option (it would hide a real race — see the
/// concurrency gotchas in CLAUDE.md). This enum is a fully-`Sendable`,
/// value-typed stand-in.
///
/// ### NSNumber Int-vs-Double fidelity
///
/// The legacy code casts numbers with `as? Int` (e.g. `usage["prompt_tokens"]
/// as? Int`). On a `JSONSerialization` `NSNumber`, `as? Int` succeeds for any
/// integral value — including one the wire encoded as a whole float
/// (`100.0 as? Int == 100`) — and `true as? Int == 1`, while `3.5 as? Int ==
/// nil`. The accessors below (`intValue`, `doubleValue`, `boolValue`)
/// reproduce that exactly so usage counts never silently drop. This is the
/// single highest-risk behaviour in the parse-once migration; it is covered
/// directly by the differential extractor tests.
public enum JSONValue: Sendable, Hashable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case int(Int)
    case bool(Bool)
    case null
}

public extension JSONValue {
    /// Builds a `JSONValue` from `JSONSerialization` output, reproducing the
    /// `NSNumber` Int-vs-Double-vs-Bool discrimination the legacy `as?` casts
    /// relied on.
    init(jsonObject: Any) {
        switch jsonObject {
        case let dict as [String: Any]:
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(dict.count)
            for (key, value) in dict {
                out[key] = JSONValue(jsonObject: value)
            }
            self = .object(out)
        case let arr as [Any]:
            self = .array(arr.map { JSONValue(jsonObject: $0) })
        case let str as String:
            self = .string(str)
        case let number as NSNumber:
            // Order matters: a JSON `true`/`false` bridges to an NSNumber
            // backed by CFBoolean, so check that *before* the numeric paths
            // (otherwise `true` would decode as `.int(1)`).
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                // Wire encoded a float. Preserve it as `.number`; the
                // `intValue` accessor still recovers a whole value via
                // `Int(exactly:)`, matching `100.0 as? Int == 100`.
                self = .number(number.doubleValue)
            } else if let intValue = Int(exactly: number.int64Value) {
                self = .int(intValue)
            } else {
                self = .number(number.doubleValue)
            }
        case is NSNull:
            self = .null
        default:
            self = .null
        }
    }

    /// Parses a JSON payload string into a `JSONValue`, or `nil` on
    /// malformed input. Used by the thin `String` wrappers on the parser
    /// namespaces so legacy callers (single-shot) keep working while the
    /// routed path uses the once-parsed `ParsedFrame.json`.
    static func parse(string: String) -> JSONValue? {
        guard let data = string.data(using: .utf8) else { return nil }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            return JSONValue(jsonObject: object)
        } catch {
            return nil
        }
    }

    // MARK: - Accessors mirroring the legacy `as?` casts

    /// Mirrors `value as? [String: Any]` for an object node.
    var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    /// Mirrors `value as? [[String: Any]]` for an array-of-objects node.
    var objectArrayValue: [[String: JSONValue]]? {
        guard case .array(let arr) = self else { return nil }
        var out: [[String: JSONValue]] = []
        out.reserveCapacity(arr.count)
        for element in arr {
            guard case .object(let dict) = element else { return nil }
            out.append(dict)
        }
        return out
    }

    /// Mirrors `value as? String`.
    var stringValue: String? {
        if case .string(let str) = self { return str }
        return nil
    }

    /// Mirrors `value as? Int` on a `JSONSerialization` `NSNumber`:
    /// integral numbers (including whole floats such as `100.0`) and booleans
    /// (`true → 1`, `false → 0`) succeed; non-integral floats return `nil`.
    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .number(let value):
            return Int(exactly: value)
        case .bool(let value):
            return value ? 1 : 0
        default:
            return nil
        }
    }

    /// Mirrors `value as? Double`.
    var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .int(let value):
            return Double(value)
        case .bool(let value):
            return value ? 1 : 0
        default:
            return nil
        }
    }

    /// Mirrors `value as? Bool` (only a JSON boolean qualifies — a numeric
    /// `1` is not a bool, matching `1 as? Bool == nil`).
    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Converts back to a `JSONSerialization`-compatible Foundation object
    /// (`[String: Any]` / `[Any]` / `String` / `NSNumber` / `NSNull`). Used
    /// when a parsed sub-tree must be re-serialised to a JSON string (e.g.
    /// Claude `tool_use.input`).
    var foundationObject: Any {
        switch self {
        case .object(let dict):
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, value) in dict {
                out[key] = value.foundationObject
            }
            return out
        case .array(let arr):
            return arr.map { $0.foundationObject }
        case .string(let str):
            return str
        case .number(let value):
            return value
        case .int(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    /// Convenience object-member subscript. Returns `nil` for non-objects or
    /// absent keys.
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }
}

/// One cloud SSE / NDJSON frame, parsed exactly once.
///
/// Built at the single parse site in ``CloudRoutedStreamParser`` and passed
/// to every consumer (`CloudStreamEventConsumer.consume(frame:)`,
/// `StreamFinalizer.finalize(frame:)`) so no downstream code re-parses the
/// payload string.
public struct ParsedFrame: Sendable {
    /// The original payload string. Some paths (error sanitisation, the
    /// stateless `SSEPayloadHandler` fallback) still consume the raw string.
    public let raw: String

    /// The parsed JSON tree, or `nil` for frames that aren't JSON objects
    /// (`[DONE]`, keepalive/heartbeat lines, malformed frames).
    public let json: JSONValue?

    /// For `NamedSSETransport` envelopes (`{"__event":..,"__data":".."}`):
    /// the unwrapped event name plus its inner `__data` payload, parsed in
    /// the same pass. `nil` for plain (non-envelope) frames.
    public let namedEvent: (name: String, dataJSON: JSONValue?, dataRaw: String)?

    public init(
        raw: String,
        json: JSONValue?,
        namedEvent: (name: String, dataJSON: JSONValue?, dataRaw: String)?
    ) {
        self.raw = raw
        self.json = json
        self.namedEvent = namedEvent
    }

    /// Parses `payload` into a `ParsedFrame` exactly once.
    ///
    /// Detects the `NamedSSETransport` envelope shape structurally and
    /// unwraps `__data` in the same pass. Malformed frames log at debug (no
    /// `try?` — production code) and yield `json == nil`.
    public static func make(from payload: String) -> ParsedFrame {
        guard let data = payload.data(using: .utf8) else {
            return ParsedFrame(raw: payload, json: nil, namedEvent: nil)
        }

        let object: Any?
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            Log.network.debug(
                "ParsedFrame: non-JSON frame skipped (\(error.localizedDescription, privacy: .public))"
            )
            return ParsedFrame(raw: payload, json: nil, namedEvent: nil)
        }

        guard let object else {
            return ParsedFrame(raw: payload, json: nil, namedEvent: nil)
        }

        let json = JSONValue(jsonObject: object)

        // Structurally detect the NamedSSETransport envelope:
        //   {"__event":"<name>","__data":"<json string>"}
        // and unwrap `__data` in this same pass so the Responses consumer
        // never re-parses the wrapper.
        if let name = json[NamedSSETransport.eventNameKey]?.stringValue,
           let inner = json[NamedSSETransport.eventDataKey]?.stringValue {
            let dataJSON: JSONValue?
            if let innerData = inner.data(using: .utf8) {
                do {
                    let innerObject = try JSONSerialization.jsonObject(with: innerData)
                    dataJSON = JSONValue(jsonObject: innerObject)
                } catch {
                    Log.network.debug(
                        "ParsedFrame: NamedSSE __data not JSON (\(error.localizedDescription, privacy: .public))"
                    )
                    dataJSON = nil
                }
            } else {
                dataJSON = nil
            }
            return ParsedFrame(
                raw: payload,
                json: json,
                namedEvent: (name: name, dataJSON: dataJSON, dataRaw: inner)
            )
        }

        return ParsedFrame(raw: payload, json: json, namedEvent: nil)
    }
}
