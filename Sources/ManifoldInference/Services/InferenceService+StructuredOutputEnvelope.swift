import Foundation

// MARK: - Reliability policy

/// Bounded retry / stall-detection policy for
/// ``InferenceService/structured(_:messages:config:policy:)`` (#2205).
///
/// This is a **distinct** reliability layer from ``ReaskPolicy``: a reask is a
/// semantic re-prompt that carries the conversation of prior failed attempts
/// so the model can see and correct its own bad output. This policy instead
/// governs full, independent retries of the *same* request after a
/// reliability-class failure (empty output, an unresponsive stream, an
/// unparsable response) — each attempt starts a fresh generation over the
/// same `messages`, nothing carried forward. Off by default: `maxRetries: 0`
/// runs exactly one attempt, matching the acceptance criterion that the
/// retry policy is opt-in.
public struct StructuredOutputReliabilityPolicy: Sendable {
    /// Number of retries **after** the first attempt. `0` (the default)
    /// disables retry — one attempt, then the classified failure is returned.
    /// Negative values are clamped to `0`.
    public var maxRetries: Int

    /// Idle-stream timeout for each attempt. When non-nil, an attempt whose
    /// stream goes this long without producing any event is cancelled and
    /// classified as ``StructuredOutputEnvelopeError/stalled(elapsed:attempts:)``
    /// — distinct from a parse failure on content the model actually sent.
    /// `nil` (the default) disables stall detection.
    public var stallTimeout: Duration?

    /// Delay before each retry (not applied before the first attempt).
    /// Defaults to a conservative 500ms — long enough to let a transient
    /// backend hiccup clear without materially slowing a single-retry call.
    public var retryDelay: Duration

    public init(
        maxRetries: Int = 0,
        stallTimeout: Duration? = nil,
        retryDelay: Duration = .milliseconds(500)
    ) {
        self.maxRetries = max(0, maxRetries)
        self.stallTimeout = stallTimeout
        self.retryDelay = retryDelay
    }
}

// MARK: - Classified failure

/// Classified failure from ``InferenceService/structured(_:messages:config:policy:)``
/// (#2205) — the reliability envelope around the structured-output primitives
/// (``ToolGrammarBuilder``, ``GBNFSchemaPreValidator``,
/// ``GenerationRuntimeHints/structuredOutput``) that every consumer doing
/// background structured extraction otherwise hand-rolls.
///
/// Each case is independently reachable and represents a genuinely different
/// failure mode a caller needs to react to differently:
///
/// - ``emptyOutput(attempts:)`` — the backend streamed zero content tokens.
///   This is the empty-output-classification requirement from #2205: a
///   grammar/JSON-mode call that produces nothing must never decode into a
///   vacuous success (an empty string trivially "parses" as invalid JSON, so
///   without this explicit check it would otherwise fall through to
///   ``unparsable(rawText:underlying:attempts:)`` and look like an ordinary
///   parse failure rather than the "the backend never really answered"
///   condition it actually is).
/// - ``unparsable(rawText:underlying:attempts:)`` — the backend streamed
///   non-empty content that failed to decode into the requested type or
///   failed schema validation. Carries the raw text for logging/debugging.
/// - ``stalled(elapsed:attempts:)`` — no stream event arrived within
///   ``StructuredOutputReliabilityPolicy/stallTimeout``. Distinct from
///   ``unparsable`` because a stall means the backend never finished
///   responding at all — there is no content to inspect.
/// - ``cancelled`` — the calling `Task` was cancelled mid-request.
public enum StructuredOutputEnvelopeError: Error, Sendable {
    /// The backend produced zero content tokens across every attempt the
    /// policy allowed. `attempts` is the total number of generations run.
    case emptyOutput(attempts: Int)

    /// The backend produced non-empty content that never decoded into the
    /// requested type (or failed schema validation) across every attempt.
    /// `rawText` and `underlying` are from the **last** attempt.
    case unparsable(rawText: String, underlying: String, attempts: Int)

    /// No stream event arrived within the configured stall timeout on the
    /// final attempt. `elapsed` is the timeout duration that fired.
    case stalled(elapsed: Duration, attempts: Int)

    /// The calling `Task` was cancelled before a result was produced.
    case cancelled
}

extension StructuredOutputEnvelopeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .emptyOutput(attempts):
            return "Structured-output request produced no content after \(attempts) attempt(s)."
        case let .unparsable(_, underlying, attempts):
            return "Structured-output request did not decode after \(attempts) attempt(s): \(underlying)"
        case let .stalled(elapsed, attempts):
            return "Structured-output request stalled (no response for \(elapsed)) after \(attempts) attempt(s)."
        case .cancelled:
            return "Structured-output request was cancelled."
        }
    }
}

extension StructuredOutputEnvelopeError: BackendError {
    /// Whether a *caller-initiated* retry (beyond what the policy already
    /// spent) has a reasonable chance of succeeding.
    ///
    /// ``emptyOutput`` and ``stalled`` are transient backend-availability
    /// conditions — worth a caller-level retry. ``unparsable`` reproduces
    /// deterministically against the same prompt/schema often enough that a
    /// bare retry is not reliably better than the reask loop
    /// (``InferenceService/respond(_:to:config:reask:)``) it should be paired
    /// with instead. ``cancelled`` was requested, not a failure to retry.
    public var isRetryable: Bool {
        switch self {
        case .emptyOutput, .stalled:
            return true
        case .unparsable, .cancelled:
            return false
        }
    }
}

// MARK: - structured<T>

extension InferenceService {

    /// Structured-output request with a reliability envelope (#2205).
    ///
    /// Composes the existing structured-output primitives — schema-to-GBNF
    /// lowering via ``StructuredOutputRouter`` (grammar → JSON-schema strict
    /// mode → prompt-level fallback, exactly as ``respond(_:to:config:)``
    /// uses), decode + ``JSONSchemaValidator`` validation, and
    /// ``GenerationStream``'s existing idle-timeout monitor — with the
    /// reliability wrapper every consumer doing background structured
    /// extraction (Fireside's knowledge-graph extraction is the motivating
    /// case) otherwise hand-rolls: stream-stall detection distinct from parse
    /// failure, a bounded retry budget across consecutive failures, and
    /// explicit empty-output classification so a grammar/JSON-mode call that
    /// streams zero content never decodes into a silent, vacuous success.
    ///
    /// Unlike ``respond(_:to:config:)``, which throws
    /// ``StructuredOutputError`` directly, this returns a `Result` so a
    /// caller can branch on the failure classification without a `do/catch`
    /// — matching the acceptance criterion that "one call yields a decoded
    /// value or a *classified* error." Errors outside that reliability
    /// taxonomy (an unencodable schema, a hard backend error such as a
    /// missing model) still `throw`, because they are not retry-shaped
    /// reliability conditions — they are configuration or environment errors
    /// the caller must fix, not conditions this envelope's retry budget can
    /// paper over.
    ///
    /// - Parameters:
    ///   - type: The type to decode the response into.
    ///   - messages: The conversation to send. Each retry re-sends the same
    ///     `messages` unchanged — this is a transport-level retry, not a
    ///     semantic reask (contrast ``respond(_:to:config:reask:)``, which
    ///     grows the conversation with the model's prior bad output).
    ///   - config: Sampling/generation configuration. Any `structuredOutput`
    ///     already set is overwritten with the schema derived from `T`.
    ///   - policy: Retry budget and stall timeout. Defaults to a single
    ///     attempt with no stall detection — fully opt-in per the acceptance
    ///     criteria.
    /// - Returns: `.success` with the decoded value, raw text, and strategy
    ///   used; `.failure` with the classified reliability error from the last
    ///   attempt.
    /// - Throws: ``StructuredOutputError/schemaEncodingFailure(_:)`` when the
    ///   schema cannot be encoded, or any non-reliability backend error.
    public func structured<T: Decodable & Sendable & SchemaProviding>(
        _ type: T.Type,
        messages: [Message],
        config: GenerationConfig = .init(),
        policy: StructuredOutputReliabilityPolicy = .init()
    ) async throws -> Result<StructuredOutput<T>, StructuredOutputEnvelopeError> {
        let schema = T.jsonSchema
        let schemaString = try Self.encodeSchema(schema)

        let attemptBudget = policy.maxRetries + 1
        var lastFailure = StructuredOutputEnvelopeError.emptyOutput(attempts: 0)

        for attempt in 1...attemptBudget {
            if Task.isCancelled { return .failure(.cancelled) }

            if attempt > 1 {
                do {
                    try await Task.sleep(for: policy.retryDelay)
                } catch {
                    return .failure(.cancelled)
                }
            }

            do {
                let (rawText, strategy) = try await runStructuredGeneration(
                    messages: messages,
                    schemaString: schemaString,
                    config: config,
                    stallTimeout: policy.stallTimeout
                )

                // Empty-output classification (#2205's core requirement): a
                // grammar/JSON-mode call that streamed nothing must surface
                // as a failure, never fall through to the decoder — an empty
                // string is not "unparsable JSON", it is "the backend never
                // answered."
                let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    lastFailure = .emptyOutput(attempts: attempt)
                    Log.inference.warning(
                        "structured() attempt \(attempt, privacy: .public)/\(attemptBudget, privacy: .public) produced empty output"
                    )
                    continue
                }

                do {
                    let result = try await Self.decodeAndValidate(
                        T.self,
                        rawText: rawText,
                        strategy: strategy,
                        schema: schema
                    )
                    return .success(result)
                } catch let error as StructuredOutputError {
                    let underlying: String
                    switch error {
                    case let .decodeFailure(_, message):
                        underlying = message
                    case let .schemaEncodingFailure(message), let .reaskBudgetExhausted(message, _):
                        underlying = message
                    }
                    lastFailure = .unparsable(rawText: rawText, underlying: underlying, attempts: attempt)
                    Log.inference.warning(
                        "structured() attempt \(attempt, privacy: .public)/\(attemptBudget, privacy: .public) failed to decode: \(underlying, privacy: .public)"
                    )
                    continue
                }
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch InferenceError.idleTimeout(let timeout) {
                lastFailure = .stalled(elapsed: timeout, attempts: attempt)
                Log.inference.warning(
                    "structured() attempt \(attempt, privacy: .public)/\(attemptBudget, privacy: .public) stalled after \(String(describing: timeout), privacy: .public)"
                )
                continue
            } catch {
                // Not a reliability-class failure this envelope's retry
                // budget is meant to absorb (e.g. a hard backend error) —
                // surface it directly rather than silently retrying or
                // mis-classifying it as one of the four cases above.
                throw error
            }
        }

        return .failure(lastFailure)
    }

    /// Convenience overload matching ``respond(_:to:config:)``'s single-prompt
    /// ergonomics — builds `messages` from a single user turn.
    public func structured<T: Decodable & Sendable & SchemaProviding>(
        _ type: T.Type,
        to prompt: String,
        config: GenerationConfig = .init(),
        policy: StructuredOutputReliabilityPolicy = .init()
    ) async throws -> Result<StructuredOutput<T>, StructuredOutputEnvelopeError> {
        try await structured(T.self, messages: [.user(prompt)], config: config, policy: policy)
    }
}
