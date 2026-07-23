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

    /// The bounded validation-reask loop (#1916) exhausted its retry budget
    /// without producing output that both decoded into `T` and satisfied the
    /// schema. Carries the last failure message (decode or validator) and the
    /// number of generation attempts that ran.
    case reaskBudgetExhausted(lastError: String, attempts: Int)
}

extension StructuredOutputError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .decodeFailure(_, underlying):
            return "Model output did not decode into the requested type: \(underlying)"
        case let .schemaEncodingFailure(detail):
            return "Failed to encode JSON schema for the requested type: \(detail)"
        case let .reaskBudgetExhausted(lastError, attempts):
            return "Structured-output reask loop exhausted after \(attempts) attempt(s): \(lastError)"
        }
    }
}

// MARK: - StructuredOutputError + BackendError
//
// `StructuredOutputError` is thrown directly by
// ``InferenceService/respond(_:to:config:)`` — the typed structured-output
// sibling of `enqueue`/`generate` on the same `InferenceService` boundary —
// so it belongs in the escapable-error set alongside `InferenceError` /
// `CloudBackendError`. `BackendError` is declared in `ManifoldContract`,
// visible here without a local import because this module's own
// `@_exported import ManifoldContract` (for source compatibility) makes it
// module-wide.
extension StructuredOutputError: BackendError {
    /// Whether retrying the same call, unchanged, has a reasonable chance of
    /// succeeding.
    ///
    /// Reasoning per case:
    /// - ``decodeFailure(rawText:underlying:)`` — a single decode miss is
    ///   often a sampling artifact; the built-in reask loop is specifically
    ///   designed to recover from this by re-prompting with the failure
    ///   context, so a bare retry has a reasonable chance of a different
    ///   (successful) generation.
    /// - ``schemaEncodingFailure(_:)`` — the caller's `SchemaProviding` type
    ///   produces a schema that fails to encode; this is deterministic given
    ///   the same type and reproduces identically on retry.
    /// - ``reaskBudgetExhausted(lastError:attempts:)`` — the bounded reask
    ///   loop already retried internally and gave up; this is the terminal
    ///   "stop trying" signal, not a fresh condition to retry again.
    public var isRetryable: Bool {
        switch self {
        case .decodeFailure:
            return true
        case .schemaEncodingFailure, .reaskBudgetExhausted:
            return false
        }
    }
}

// MARK: - Reask policy

/// Budget for the bounded validation-reask loop on structured output (#1916).
///
/// When a typed ``InferenceService/respond(_:to:config:reask:)`` round-trip
/// produces output that fails to decode into `T` **or** fails
/// ``JSONSchemaValidator`` schema validation, the loop re-prompts the model
/// with the failure message inside this budget before throwing
/// ``StructuredOutputError/reaskBudgetExhausted(lastError:attempts:)``.
///
/// This is a **distinct** failure class from transport-level retry
/// (``RetryPolicy``, which handles HTTP transient backoff): a reask is a fresh
/// generation that carries the conversation of prior failed attempts, asking
/// the model to correct semantically invalid output. v1 re-runs only the final
/// structured-output turn, not the full tool loop.
public struct ReaskPolicy: Sendable {
    /// Total number of generation attempts, including the first. `1` disables
    /// reask (one attempt, then throw on failure).
    public var maxAttempts: Int
    /// When `true`, the model's bad output is echoed back as an assistant turn
    /// in the reask conversation so it can see what it produced.
    public var includeRawOutput: Bool

    public init(maxAttempts: Int = 2, includeRawOutput: Bool = true) {
        self.maxAttempts = maxAttempts
        self.includeRawOutput = includeRawOutput
    }
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
    ///   the produced text does not decode into `T`; or any generation error
    ///   from the backend. A schema-encoding failure for a non-guided backend
    ///   degrades gracefully to `.jsonPrompting` (logged) rather than throwing
    ///   — see ``GenerationQueue/structuredOutputTarget(from:capabilities:)``.
    public func respond<T: Decodable & Sendable & SchemaProviding>(
        _ type: T.Type,
        to prompt: String,
        config: GenerationConfig = .init()
    ) async throws -> StructuredOutput<T> {
        let schema = T.jsonSchema
        let (rawText, strategy) = try await runStructuredGeneration(
            messages: [.user(prompt)],
            guidedType: type,
            config: config
        )
        return try await Self.decodeAndValidate(
            T.self,
            rawText: rawText,
            strategy: strategy,
            schema: schema
        )
    }

    /// Bounded validation-reask variant of ``respond(_:to:config:)`` (#1916).
    ///
    /// Runs the structured-output round-trip, and when the produced text fails
    /// to decode into `T` **or** fails ``JSONSchemaValidator`` schema
    /// validation, re-prompts the model with the failure message inside the
    /// ``ReaskPolicy`` budget. Each reask carries the conversation of prior
    /// failed attempts: optionally the model's bad output (when
    /// ``ReaskPolicy/includeRawOutput``) plus a user turn naming the violation
    /// and demanding valid JSON.
    ///
    /// This reask budget is **distinct** from transport-level retry
    /// (``RetryPolicy``): it re-runs the final structured-output turn for a
    /// *semantic* failure (bad decode / schema violation), not an HTTP
    /// transient. v1 re-runs only that final turn, not the full tool loop.
    ///
    /// - Parameters:
    ///   - type: The type to decode the response into.
    ///   - prompt: The user prompt.
    ///   - config: Sampling/generation configuration; `structuredOutput` is
    ///     overwritten with the schema derived from `T` on every attempt.
    ///   - reask: The retry budget. `maxAttempts: 1` disables reask.
    /// - Returns: The decoded, schema-valid value, raw text, and strategy.
    /// - Throws: ``StructuredOutputError/reaskBudgetExhausted(lastError:attempts:)``
    ///   when the budget is exhausted without a valid response; or any
    ///   generation error from the backend. A schema-encoding failure for a
    ///   non-guided backend degrades gracefully to `.jsonPrompting` (logged)
    ///   rather than throwing — see
    ///   ``GenerationQueue/structuredOutputTarget(from:capabilities:)``.
    public func respond<T: Decodable & Sendable & SchemaProviding>(
        _ type: T.Type,
        to prompt: String,
        config: GenerationConfig = .init(),
        reask: ReaskPolicy = .init()
    ) async throws -> StructuredOutput<T> {
        let schema = T.jsonSchema

        // The conversation grows across attempts: it starts with the user
        // prompt and, on each failure, gains the model's (bad) output plus a
        // corrective user turn. A reask is a fresh generation over this
        // conversation — NOT a transport retry of the same request.
        var messages: [Message] = [.user(prompt)]
        let attemptBudget = max(1, reask.maxAttempts)
        var lastError = "no attempt ran"

        for attempt in 1...attemptBudget {
            let (rawText, strategy) = try await runStructuredGeneration(
                messages: messages,
                guidedType: type,
                config: config
            )

            do {
                return try await Self.decodeAndValidate(
                    T.self,
                    rawText: rawText,
                    strategy: strategy,
                    schema: schema
                )
            } catch let error as StructuredOutputError {
                lastError = Self.reaskMessage(for: error)
                Log.inference.warning(
                    "structured-output attempt \(attempt, privacy: .public)/\(attemptBudget, privacy: .public) failed: \(lastError, privacy: .public)"
                )

                // Budget exhausted — stop before staging another turn.
                if attempt >= attemptBudget { break }

                if reask.includeRawOutput {
                    messages.append(.assistant(rawText))
                }
                messages.append(.user(
                    "Your previous response failed validation: \(lastError). "
                    + "Return only valid JSON matching the schema."
                ))
            }
        }

        throw StructuredOutputError.reaskBudgetExhausted(
            lastError: lastError,
            attempts: attemptBudget
        )
    }

    // MARK: - Shared round-trip steps

    /// Encodes a ``JSONSchemaValue`` to a sorted-keys JSON string for staging
    /// on the generation config. Throws ``StructuredOutputError/schemaEncodingFailure(_:)``.
    ///
    /// `internal` (not `private`) so ``InferenceService/structured(_:messages:config:policy:)``
    /// (#2205), a sibling file in the same module, can reuse it instead of
    /// re-deriving the same encode step. Not `package` — no cross-package
    /// consumer exists, and `@testable` covers the tests.
    static func encodeSchema(_ schema: JSONSchemaValue) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(schema)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw StructuredOutputError.schemaEncodingFailure(String(describing: error))
        }
    }

    /// Stages the schema on config, enqueues a single generation over
    /// `messages`, and drains the content tokens to a string. Returns the raw
    /// text and the router-selected strategy.
    ///
    /// - Parameter stallTimeout: When non-nil, wraps the queue's stream in a
    ///   fresh ``GenerationStream`` idle-timeout monitor (see
    ///   ``GenerationStream/init(_:idleTimeout:)``) so a gap longer than this
    ///   duration between events throws ``InferenceError/idleTimeout(_:)``.
    ///   `nil` (the default, used by ``respond(_:to:config:)``) disables stall
    ///   detection — the queue's own stream is drained unmonitored, matching
    ///   pre-#2205 behavior exactly. Reusing ``GenerationStream``'s existing
    ///   monitor here — rather than a bespoke timer — is why the structured-
    ///   output reliability envelope (#2205) needed no new stall-detection
    ///   primitive of its own.
    ///
    /// **Slot freeing on abnormal termination.** The generation queue is
    /// strictly serial and its active slot clears only when the active task
    /// finishes. A stall (or a mid-stream cancellation) stops *this* function
    /// from draining, but the backend behind the queue is still hung, so the
    /// slot would stay occupied forever — wedging every later request, since
    /// chat and background structured extraction share one `InferenceService`
    /// queue (AGENTS.md "Service sharing"). So on ANY terminal throw we
    /// ``InferenceService/cancel(_:)`` the enqueue token, which calls the
    /// backend's `stopGeneration()`, cancels the active task, and synchronously
    /// clears the slot + drains the queue — freeing it before the envelope's
    /// retry re-enqueues. `cancel` is a no-op when the request already
    /// finished, so the normal-completion path pays nothing.
    ///
    /// `internal` (not `private`) so ``InferenceService/structured(_:messages:config:policy:)``
    /// (#2205), a sibling file in the same module, can reuse this exact
    /// staging/draining/strategy-reporting logic instead of re-deriving it.
    /// Not `package` — no cross-package consumer exists, and `@testable`
    /// covers the tests.
    func runStructuredGeneration(
        messages: [Message],
        guidedType: any Decodable.Type,
        config: GenerationConfig,
        stallTimeout: Duration? = nil
    ) async throws -> (rawText: String, strategy: StructuredOutputStrategy) {
        // Stage `.guided(T.self)` (#2354) rather than a bare JSON-Schema string
        // — the concrete type is what a guided-capable backend (Foundation)
        // needs to build native GuidedGeneration. The queue's router wiring
        // (#1915/#2354) recovers the type's schema via its `SchemaProviding`
        // conformance for every OTHER backend (grammar-lowering, jsonSchema, or
        // jsonPrompting), so this single staged value serves every tier — see
        // `GenerationQueue.structuredOutputTarget(from:capabilities:)`.
        let hints = GenerationRuntimeHints(structuredOutput: .guided(guidedType))

        let (token, queueStream) = try enqueue(messages: messages, config: config, hints: hints)

        // The strategy the router actually chose for the serving backend, set
        // on the stream by the queue at enqueue time. Reading it back is the
        // single source of truth — no recomputation against a capability set
        // that might differ from the one the queue dispatched to. `nil` means
        // the request carried no resolvable target (treated as prompt-level).
        let strategy = queueStream.structuredOutputStrategy ?? .jsonPrompting

        // Drain to a string. Collect only content tokens — thinking and tool
        // events are not part of the structured payload. When a stall timeout
        // is configured, iterate a monitored wrapper instead of the queue
        // stream directly so a gap between events throws
        // `InferenceError.idleTimeout` rather than hanging until the backend
        // itself gives up (or never does).
        var collected = ""
        do {
            if let stallTimeout {
                let monitored = GenerationStream(queueStream.events, idleTimeout: stallTimeout)
                for try await event in monitored {
                    if case .token(let fragment) = event {
                        collected += fragment
                    }
                }
            } else {
                for try await event in queueStream {
                    if case .token(let fragment) = event {
                        collected += fragment
                    }
                }
            }
        } catch {
            // A stall, a mid-stream cancellation, or a backend error left the
            // queue's active slot occupied (the backend may still be running).
            // Free it before rethrowing so the envelope's retry — and every
            // other request sharing this serial queue — can proceed. No-op if
            // the request already finished (token no longer active/queued).
            cancel(token)
            throw error
        }

        return (collected, strategy)
    }

    /// Decodes `rawText` into `T` and validates it against `schema`.
    ///
    /// A decode failure surfaces ``StructuredOutputError/decodeFailure(rawText:underlying:)``;
    /// schema-valid-but-rule-violating JSON (enum/required/bounds) surfaces a
    /// `decodeFailure` carrying the validator's model-readable message. Both
    /// are the reask triggers for ``respond(_:to:config:reask:)``.
    ///
    /// `internal` (not `private`) so ``InferenceService/structured(_:messages:config:policy:)``
    /// (#2205), a sibling file in the same module, can reuse the same
    /// decode+validate step. Not `package` — no cross-package consumer exists.
    static func decodeAndValidate<T: Decodable & Sendable>(
        _ type: T.Type,
        rawText: String,
        strategy: StructuredOutputStrategy,
        schema: JSONSchemaValue
    ) async throws -> StructuredOutput<T> {
        // Validate the extracted JSON against the schema BEFORE decoding so the
        // model gets the rich, model-readable violation message (enum/required/
        // bounds) rather than an opaque Swift decoding error. The validator
        // fails closed on unsupported keywords; treat that as "skip validation"
        // and let the decoder be the authority, since refusing here would block
        // any schema the decoder itself handles fine.
        let jsonText = extractJSON(from: rawText)
        let validator = JSONSchemaValidator()
        if let failure = validator.validate(arguments: jsonText, against: schema),
           !failure.modelReadableMessage.contains("unsupported schema feature") {
            throw StructuredOutputError.decodeFailure(
                rawText: rawText,
                underlying: failure.modelReadableMessage
            )
        }

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

    /// Extracts a concise, model-readable message from a structured-output
    /// error for embedding in the reask prompt.
    private static func reaskMessage(for error: StructuredOutputError) -> String {
        switch error {
        case let .decodeFailure(_, underlying):
            return underlying
        case let .schemaEncodingFailure(message):
            return message
        case let .reaskBudgetExhausted(lastError, _):
            return lastError
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
