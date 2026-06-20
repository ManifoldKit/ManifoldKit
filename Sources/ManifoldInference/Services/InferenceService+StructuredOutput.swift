import Foundation

// MARK: - Schema Providing

/// A type that can describe itself as a JSON Schema for structured-output
/// generation.
///
/// Conformance is the only requirement of ``InferenceService/respond(_:to:config:)``
/// beyond `Decodable`. The `@ToolSchema` macro (trait-gated behind `Macros`)
/// synthesizes `static var jsonSchema` for you, but it is **not** required —
/// any type can conform by hand, which keeps `respond` usable in default builds
/// where the macro is off.
///
/// ```swift
/// struct Weather: Decodable, Sendable, SchemaProviding {
///     let city: String
///     let celsius: Double
///     static var jsonSchema: JSONSchemaValue {
///         .object([
///             "type": .string("object"),
///             "properties": .object([
///                 "city": .object(["type": .string("string")]),
///                 "celsius": .object(["type": .string("number")]),
///             ]),
///             "required": .array([.string("city"), .string("celsius")]),
///         ])
///     }
/// }
/// ```
public protocol SchemaProviding {
    /// The JSON Schema describing the decoded shape of this type.
    static var jsonSchema: JSONSchemaValue { get }
}

// MARK: - Result

/// The result of a typed structured-output round-trip.
public struct StructuredOutput<T: Decodable & Sendable>: Sendable {
    /// The decoded value.
    public let value: T
    /// The raw text the model produced before decoding. Useful for logging,
    /// debugging, and reask loops (#1916).
    public let rawText: String
    /// The structured-output strategy the router selected for the active
    /// backend. `.jsonPrompting` indicates the backend offered no constrained
    /// decoding and the schema was injected as a prompt instruction.
    public let strategy: StructuredOutputStrategy

    public init(value: T, rawText: String, strategy: StructuredOutputStrategy) {
        self.value = value
        self.rawText = rawText
        self.strategy = strategy
    }
}

// MARK: - Errors

/// Failures specific to the typed structured-output round-trip.
///
/// Surfaced by ``InferenceService/respond(_:to:config:)``. A clean, public
/// typed error is the precondition for the structured-output reask loop
/// (#1916) — callers inspect ``decodeFailure`` to decide whether to retry with
/// the raw text fed back to the model.
public enum StructuredOutputError: Error, Sendable {
    /// The model produced text that did not decode into the requested type.
    /// Carries the raw text and the underlying decoding error so a reask loop
    /// can include both in its retry prompt.
    case decodeFailure(rawText: String, underlying: String)

    /// The JSON schema for the requested type could not be encoded to a string.
    case schemaEncodingFailure(String)
}

// MARK: - respond<T>

extension InferenceService {

    /// Generates a single response constrained to decode into `T`.
    ///
    /// Derives a JSON schema from `T`, stages it on the generation config, and
    /// routes through the queue where ``StructuredOutputRouter`` selects the
    /// strongest constrained-decoding mechanism the active backend supports
    /// (GBNF grammar → JSON-schema strict mode → prompt-level instruction).
    /// Runs one generation, drains the stream to a string, and decodes into `T`.
    ///
    /// The macro is optional: any `Decodable & Sendable & SchemaProviding` type
    /// works, so this is usable in default builds where the `Macros` trait is off.
    ///
    /// This shares the generation queue with chat turns — the request is
    /// enqueued and serializes behind any in-flight generation rather than
    /// dispatching out-of-band. The router wiring lives at the queue's enqueue
    /// chokepoint, which is the only place the serving backend's capabilities
    /// are known.
    ///
    /// - Parameters:
    ///   - type: The type to decode the response into.
    ///   - prompt: The user prompt.
    ///   - config: Sampling/generation configuration. Any `structuredOutput`
    ///     already set is overwritten with the schema derived from `T`.
    /// - Returns: The decoded value, the raw model text, and the strategy used.
    /// - Throws: ``StructuredOutputError/decodeFailure(rawText:underlying:)`` when
    ///   the produced text does not decode into `T`;
    ///   ``StructuredOutputError/schemaEncodingFailure(_:)`` when the schema
    ///   cannot be encoded; or any generation error from the backend.
    public func respond<T: Decodable & Sendable & SchemaProviding>(
        _ type: T.Type,
        to prompt: String,
        config: GenerationConfig = .init()
    ) async throws -> StructuredOutput<T> {
        let schema = T.jsonSchema

        // Encode the schema to a string. The queue stages this on config and
        // lowers it to GBNF (for grammar-capable backends) or injects it as a
        // prompt instruction (weak backends) when the router runs.
        let schemaString: String
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(schema)
            schemaString = String(decoding: data, as: UTF8.self)
        } catch {
            throw StructuredOutputError.schemaEncodingFailure(String(describing: error))
        }

        // Stage the schema on config. The queue's router wiring (#1915) reads
        // `structuredOutput`, lowers the schema to GBNF when the active backend
        // supports grammar-constrained sampling, and selects the strongest
        // mechanism — leaving `config.grammar` untouched for schema-only
        // backends so they never see a grammar they'd reject.
        var routedConfig = config
        routedConfig.structuredOutput = .jsonSchema(schemaString)

        let (_, stream) = try enqueue(
            messages: [.user(prompt)],
            config: routedConfig
        )

        // Drain to a string. Collect only content tokens — thinking and tool
        // events are not part of the structured payload.
        var collected = ""
        for try await event in stream {
            if case .token(let fragment) = event {
                collected += fragment
            }
        }

        let rawText = collected

        // The strategy the router actually chose for the serving backend, set
        // on the stream by the queue at enqueue time. Reading it back is the
        // single source of truth — no recomputation against a capability set
        // that might differ from the one the queue dispatched to. `nil` means
        // the request carried no resolvable target (treated as prompt-level).
        let strategy = stream.structuredOutputStrategy ?? .jsonPrompting

        // Decode off the main actor — small payloads, but no reason to block UI.
        do {
            let value = try await Self.decode(T.self, from: rawText)
            return StructuredOutput(value: value, rawText: rawText, strategy: strategy)
        } catch let error as StructuredOutputError {
            throw error
        } catch {
            throw StructuredOutputError.decodeFailure(
                rawText: rawText,
                underlying: String(describing: error)
            )
        }
    }

    /// Decodes JSON text into `T` off the main actor.
    ///
    /// `nonisolated` so the JSON parse runs on the cooperative pool rather than
    /// the `@MainActor`. Tolerates surrounding prose / code fences from
    /// prompt-level fallbacks by extracting the first balanced JSON object.
    nonisolated static func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        from text: String
    ) async throws -> T {
        let jsonText = extractJSON(from: text)
        guard let data = jsonText.data(using: .utf8) else {
            throw StructuredOutputError.decodeFailure(
                rawText: text,
                underlying: "Response was not valid UTF-8."
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw StructuredOutputError.decodeFailure(
                rawText: text,
                underlying: String(describing: error)
            )
        }
    }

    /// Extracts the first balanced top-level JSON object/array from `text`,
    /// stripping markdown code fences and surrounding prose that weak backends
    /// emit alongside the JSON in the prompt-fallback path. Returns the input
    /// unchanged when no object/array delimiter is found (let the decoder
    /// produce the authoritative error).
    nonisolated static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return trimmed
        }
        let opener = trimmed[start]
        let closer: Character = opener == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaped = false
        var endIndex: String.Index?
        var idx = start
        while idx < trimmed.endIndex {
            let ch = trimmed[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else if ch == "\"" {
                inString = true
            } else if ch == opener {
                depth += 1
            } else if ch == closer {
                depth -= 1
                if depth == 0 {
                    endIndex = trimmed.index(after: idx)
                    break
                }
            }
            idx = trimmed.index(after: idx)
        }
        guard let endIndex else { return trimmed }
        return String(trimmed[start..<endIndex])
    }
}
