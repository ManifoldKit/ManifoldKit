import Foundation
import ManifoldModelCatalog

// MARK: - PartialSnapshot

/// A progressively-filled snapshot of a structured-output generation as it
/// streams (#1917).
///
/// Each token delta produces a new snapshot. ``fields`` holds the best-effort
/// parse of the accumulated buffer (after a lenient close step auto-terminates
/// any open string/object/array), so SwiftUI can render a partial object as it
/// arrives. ``decoded`` is `nil` until the *raw* buffer parses cleanly into `T`
/// — i.e. once the model has emitted a complete, valid JSON document. The
/// lenient close is only used to populate ``fields``; `T` is never decoded from
/// a synthetically-closed buffer, so a final `decoded` value never reflects
/// guessed structure.
///
/// This is a side-channel surface: the ``GenerationEvent`` vocabulary is frozen
/// for 1.0 and gains no snapshot case. ``InferenceService/streamObject(_:to:config:)``
/// drains the same token stream `respond` does and yields these snapshots on a
/// dedicated `AsyncThrowingStream`.
public struct PartialSnapshot<T: Decodable & Sendable>: Sendable {
    /// Best-effort parse of the accumulated buffer so far, after a lenient
    /// close step. Empty until the buffer contains enough to parse a partial
    /// object. Keys appear incrementally as the model emits them.
    public let fields: [String: JSONSchemaValue]

    /// The decoded value, non-`nil` once the accumulated *raw* buffer (no
    /// lenient close applied) decodes cleanly into `T`. Typically becomes
    /// non-`nil` on the final snapshot.
    public let decoded: T?

    /// The accumulated buffer for this snapshot — every content token seen so
    /// far, concatenated.
    public let rawText: String

    public init(fields: [String: JSONSchemaValue], decoded: T?, rawText: String) {
        self.fields = fields
        self.decoded = decoded
        self.rawText = rawText
    }
}

// MARK: - streamObject / streamEach

extension InferenceService {

    /// Streams progressively-filled snapshots of a structured-output generation.
    ///
    /// Mirrors ``respond(_:to:config:)`` — derives a JSON schema from `T`, stages
    /// it on the config, and enqueues through the queue so the
    /// ``StructuredOutputRouter`` selects the strongest constrained-decoding
    /// mechanism the active backend supports. But instead of draining to a single
    /// value, it yields a ``PartialSnapshot`` on **every content-token delta**:
    /// the buffer is leniently closed, parsed into ``PartialSnapshot/fields``,
    /// and decoded into `T` when the raw buffer is complete.
    ///
    /// This gives SwiftUI a stream of partial objects rather than raw token text,
    /// so a view can render `name` before `age` arrives. The
    /// ``GenerationEvent`` vocabulary is untouched (frozen for 1.0) — snapshots
    /// travel on this dedicated stream.
    ///
    /// v1 uses the uniform lenient-reparse path for **all** backends. Foundation's
    /// native Apple snapshot stream is a follow-up; this path works against every
    /// backend that emits `.token` deltas.
    ///
    /// - Parameters:
    ///   - type: The type each completed buffer should decode into.
    ///   - prompt: The user prompt.
    ///   - config: Sampling/generation configuration. Any `structuredOutput`
    ///     already set is overwritten with the schema derived from `T`.
    /// - Returns: A stream of ``PartialSnapshot`` values, one per token delta.
    ///   The stream finishes when generation completes and throws on schema
    ///   encoding failure or any backend/generation error.
    public func streamObject<T: Decodable & Sendable & SchemaProviding>(
        _ type: T.Type,
        to prompt: String,
        config: GenerationConfig = .init()
    ) -> AsyncThrowingStream<PartialSnapshot<T>, Error> {
        AsyncThrowingStream { continuation in
            // `Task { }` inherits this @MainActor — the enqueue + stream drain
            // must run on the actor that owns the queue. Never Task.detached
            // (CLAUDE.md gotcha #5).
            let task = Task { @MainActor in
                do {
                    let hints = try Self.routedStructuredHints(for: T.self)
                    let (_, stream) = try self.enqueue(
                        messages: [.user(prompt)],
                        config: config,
                        hints: hints
                    )

                    var buffer = ""
                    for try await event in stream {
                        if Task.isCancelled { break }
                        guard case .token(let fragment) = event else { continue }
                        buffer += fragment
                        let snapshot = await Self.makeSnapshot(T.self, from: buffer)
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams one decoded `T` per completed element of a top-level JSON array.
    ///
    /// Where ``streamObject(_:to:config:)`` snapshots a single object as it
    /// fills, `streamEach` is the collection mode: the model is expected to emit
    /// a JSON array of `T`, and each element is decoded and yielded the moment
    /// its closing brace/bracket lands. Useful for "stream me a list" UIs that
    /// want to append rows as they complete rather than waiting for the whole
    /// array.
    ///
    /// The schema staged on the config describes `T` (the element), not the
    /// array — backends that constrain on the element shape still produce a
    /// valid stream of elements; weak backends get the element schema as a
    /// prompt instruction. Element boundaries are detected structurally from the
    /// raw token stream (brace/bracket depth, string-aware), so no lenient close
    /// is involved: each element is decoded from its exact, complete text.
    ///
    /// - Parameters:
    ///   - type: The element type to decode.
    ///   - prompt: The user prompt.
    ///   - config: Generation configuration; `structuredOutput` is overwritten
    ///     with the schema for `T`.
    /// - Returns: A stream of decoded `T` values, one per completed array
    ///   element.
    public func streamEach<T: Decodable & Sendable & SchemaProviding>(
        _ type: T.Type,
        to prompt: String,
        config: GenerationConfig = .init()
    ) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let hints = try Self.routedStructuredHints(for: T.self)
                    let (_, stream) = try self.enqueue(
                        messages: [.user(prompt)],
                        config: config,
                        hints: hints
                    )

                    var extractor = TopLevelArrayElementExtractor()
                    for try await event in stream {
                        if Task.isCancelled { break }
                        guard case .token(let fragment) = event else { continue }
                        for elementText in extractor.consume(fragment) {
                            let value = try await Self.decode(T.self, from: elementText)
                            continuation.yield(value)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Shared helpers

    /// Builds the runtime hints that stage `T`'s schema on `structuredOutput`,
    /// matching `respond`'s lowering so `streamObject`/`streamEach` route through
    /// the same `StructuredOutputRouter` wiring at the queue chokepoint.
    static func routedStructuredHints<T: SchemaProviding>(
        for type: T.Type
    ) throws -> GenerationRuntimeHints {
        let schema = T.jsonSchema
        let schemaString: String
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(schema)
            schemaString = String(decoding: data, as: UTF8.self)
        } catch {
            throw StructuredOutputError.schemaEncodingFailure(String(describing: error))
        }
        return GenerationRuntimeHints(structuredOutput: .jsonSchema(schemaString))
    }

    /// Produces a snapshot from the accumulated buffer: lenient-close → parse
    /// `fields`, and attempt a clean decode of `T` from the *raw* (un-closed)
    /// buffer. `nonisolated` so the parse/decode runs off the main actor.
    nonisolated static func makeSnapshot<T: Decodable & Sendable>(
        _ type: T.Type,
        from buffer: String
    ) async -> PartialSnapshot<T> {
        let fields = parseFields(from: buffer)
        let decoded = decodeClean(T.self, from: buffer)
        return PartialSnapshot(fields: fields, decoded: decoded, rawText: buffer)
    }

    /// Best-effort partial-field parse. Extracts the leading JSON object from the
    /// buffer (tolerating prose/fences via ``extractJSON(from:)``), leniently
    /// closes it, and decodes to a `[String: JSONSchemaValue]`. Returns empty
    /// when nothing parses yet.
    nonisolated static func parseFields(from buffer: String) -> [String: JSONSchemaValue] {
        let candidate = extractJSON(from: buffer)
        guard let closed = LenientJSONCloser.close(candidate),
              let data = closed.data(using: .utf8) else {
            return [:]
        }
        do {
            let value = try JSONDecoder().decode(JSONSchemaValue.self, from: data)
            if case .object(let dict) = value { return dict }
            return [:]
        } catch {
            // Partial buffers frequently fail to parse mid-stream — that is the
            // expected steady state, not an error worth logging on every token.
            return [:]
        }
    }

    /// Attempts a clean decode of `T` from the raw buffer with no lenient close.
    /// Returns `nil` until the buffer holds a complete, valid document — so
    /// ``PartialSnapshot/decoded`` never reflects guessed structure.
    nonisolated static func decodeClean<T: Decodable & Sendable>(
        _ type: T.Type,
        from buffer: String
    ) -> T? {
        let candidate = extractJSON(from: buffer)
        guard let data = candidate.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }
}
