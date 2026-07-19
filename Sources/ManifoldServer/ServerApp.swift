#if Server
import ManifoldInference
import Foundation
import Hummingbird
import HTTPTypes
import os

// MARK: - Custom request context with configurable body-size limit

/// Publishes the currently-running ``ServerApp``'s configured
/// `maxServerRequestBodyBytes` to per-request context creation.
///
/// Hummingbird constructs a `RequestContext` per request via
/// `Self.init(source:)` — a static requirement with no access to the
/// `ServerApp` instance that built the router. `ServerApp.makeApplication()`
/// publishes its instance's `configuration.maxServerRequestBodyBytes` here
/// before constructing the router, so the limit actually enforced matches
/// the `ServerConfiguration` passed to that instance rather than always
/// falling back to the process-global `ManifoldConfiguration.shared` default.
/// `OSAllocatedUnfairLock` makes the box `Sendable`; the box is seeded from
/// `ManifoldConfiguration.shared` so a `ManifoldServerRequestContext` created
/// before any `ServerApp.makeApplication()` call (e.g. in an isolated unit
/// test) still gets a sane default.
///
/// Known limitation: the box is process-wide, so two `ServerApp` instances
/// running **concurrently in one process** would clobber each other's limit —
/// last `makeApplication()` wins for all subsequent requests. That is
/// acceptable for the current reality (the `manifold-server` CLI runs exactly
/// one `ServerApp` per process; tests build apps serially). Revisit with a
/// per-router mechanism (e.g. a body-limit middleware) if multi-instance
/// hosting in one process ever becomes a supported shape.
private let maxUploadSizeBox = OSAllocatedUnfairLock<Int>(
    initialState: ManifoldConfiguration.shared.maxServerRequestBodyBytes
)

/// A Hummingbird `RequestContext` that enforces the server's configured
/// maximum upload size. Hummingbird rejects bodies larger than
/// `maxUploadSize` with HTTP 413 before any handler logic runs.
internal struct ManifoldServerRequestContext: RequestContext {
    internal var coreContext: CoreRequestContextStorage
    internal let maxUploadSize: Int

    internal init(source: Source) {
        self.coreContext = .init(source: source)
        self.maxUploadSize = maxUploadSizeBox.withLock { $0 }
    }
}

internal struct ServerHealth: Codable, Equatable, Sendable {
    internal var status: String

    internal init(status: String = "ok") {
        self.status = status
    }
}

internal struct ServerApp: Sendable {
    internal let configuration: ServerConfiguration
    internal let backendProvider: any ServerBackendProvider
    internal let adapter: any ChatCompletionsAdapter
    internal let metrics: ServerMetrics
    internal let generationGate: AsyncSemaphore
    internal let authMiddleware: any RequestAuthMiddleware

    internal init(
        configuration: ServerConfiguration = ServerConfiguration(),
        backendProvider: any ServerBackendProvider = UnavailableServerBackendProvider(),
        adapter: any ChatCompletionsAdapter = DefaultChatCompletionsAdapter(),
        metrics: ServerMetrics = ServerMetrics(),
        authMiddleware: (any RequestAuthMiddleware)? = nil
    ) {
        self.configuration = configuration
        self.backendProvider = backendProvider
        self.adapter = adapter
        self.metrics = metrics
        self.generationGate = AsyncSemaphore(value: configuration.parallelSlots)
        // Back-compat: when no explicit middleware is supplied, the legacy
        // `apiKey` field still works — it's wrapped in a BearerTokenMiddleware.
        // An empty/nil apiKey means anonymous access (today's default).
        if let authMiddleware {
            self.authMiddleware = authMiddleware
        } else if let apiKey = configuration.apiKey, !apiKey.isEmpty {
            self.authMiddleware = BearerTokenMiddleware(token: apiKey)
        } else {
            self.authMiddleware = AnonymousAuthMiddleware()
        }
    }

    internal func health() -> ServerHealth { ServerHealth() }

    internal func makeApplication() -> some ApplicationProtocol {
        // Publish this instance's configured body-size limit before the
        // router (and therefore per-request `ManifoldServerRequestContext`
        // creation) is built — see `maxUploadSizeBox`'s doc comment.
        maxUploadSizeBox.withLock { $0 = configuration.maxServerRequestBodyBytes }

        let router = Router(context: ManifoldServerRequestContext.self)
        router.add(middleware: corsMiddleware())

        router.get("/health") { _, _ in
            jsonResponse(health())
        }

        router.get("/v1/models") { request, _ in
            if let unauthorized = await authorizationFailure(for: request) {
                return unauthorized
            }
            metrics.recordRequestStarted()
            do {
                let models = try await backendProvider.listModelRecords()
                metrics.recordRequestCompleted()
                return jsonResponse(ModelsListResponse(modelRecords: models))
            } catch {
                metrics.recordFailure()
                metrics.recordRequestCompleted()
                let envelope = ChatCompletionErrorEnvelope.from(error)
                return jsonResponse(envelope, status: httpStatus(for: error))
            }
        }

        router.post("/v1/chat/completions") { request, context in
            if let unauthorized = await authorizationFailure(for: request) {
                return unauthorized
            }
            metrics.recordRequestStarted()
            do {
                let completionRequest = try await decodeBody(ChatCompletionRequest.self, from: request, context: context)
                let response = try await chatCompletionResponse(for: completionRequest)
                metrics.recordRequestCompleted()
                return response
            } catch {
                metrics.recordFailure()
                metrics.recordRequestCompleted()
                let envelope = ChatCompletionErrorEnvelope.from(error)
                return jsonResponse(envelope, status: httpStatus(for: error))
            }
        }

        router.post("/v1/embeddings") { request, context in
            if let unauthorized = await authorizationFailure(for: request) {
                return unauthorized
            }
            metrics.recordRequestStarted()
            do {
                let embedRequest = try await decodeBody(EmbedRequest.self, from: request, context: context)
                let response = try await embeddingResponse(for: embedRequest)
                metrics.recordRequestCompleted()
                return jsonResponse(response)
            } catch {
                metrics.recordFailure()
                metrics.recordRequestCompleted()
                let envelope = ChatCompletionErrorEnvelope.from(error)
                return jsonResponse(envelope, status: httpStatus(for: error))
            }
        }

        if configuration.metricsEnabled {
            router.get("/metrics") { request, _ in
                if let unauthorized = await authorizationFailure(for: request) {
                    return unauthorized
                }
                return metricsResponse()
            }
        }

        let appConfiguration = ApplicationConfiguration(
            address: .hostname(configuration.host, port: configuration.port),
            serverName: "ManifoldServer"
        )
        return Application(router: router, configuration: appConfiguration)
    }

    internal func run() async throws {
        try await makeApplication().runService()
    }

    private func corsMiddleware() -> CORSMiddleware<ManifoldServerRequestContext> {
        let allowOrigin: CORSMiddleware<ManifoldServerRequestContext>.AllowOrigin
        if configuration.unsafeCORS {
            allowOrigin = .all
        } else if let corsOrigin = configuration.corsOrigin {
            allowOrigin = .custom(corsOrigin)
        } else {
            allowOrigin = .none
        }
        return CORSMiddleware(
            allowOrigin: allowOrigin,
            allowHeaders: [.authorization, .contentType, .accept, .origin],
            allowMethods: [.get, .post, .options]
        )
    }

    private func authorizationFailure(for request: Request) async -> Response? {
        // AnonymousAuthMiddleware always succeeds, so the cost here is one
        // protocol dispatch per request — same shape as the original guard.
        do {
            _ = try await authMiddleware.authenticate(AuthRequest.from(request))
            return nil
        } catch {
            return errorResponse(
                "Missing or invalid bearer token.",
                status: .unauthorized,
                type: "invalid_request_error",
                code: "invalid_api_key"
            )
        }
    }

    /// `stopGeneration()`'s contract is backend-wide, not per-request
    /// (`InferenceBackend.swift`), and `TraitAwareServerBackendProvider`
    /// hands out a single cached backend instance per model. Under
    /// `parallelSlots > 1` two concurrent requests share that instance.
    ///
    /// Per-request **history** is no longer a hazard on that shared instance:
    /// it travels on the `generate(…)` call stack via `hints.history`, consumed
    /// synchronously while the request body is built, so no concurrent request
    /// can clobber it (#2312, fixed). **Cancellation** is the remaining
    /// shared-instance hazard: `stopGeneration()` cancels the whole backend, so
    /// firing it for one timed-out request would also kill a sibling's healthy
    /// in-flight generation. Real per-request cancellation needs an
    /// `InferenceBackend` contract change (a separate follow-up — out of scope
    /// here). Only cancel for real when at most one generation can be in flight
    /// at a time; otherwise the timeout still ends the *request* (task
    /// abandonment), just not the backend call.
    private var canCancelInFlightGenerationOnTimeout: Bool {
        configuration.parallelSlots == 1
    }

    private func chatCompletionResponse(for request: ChatCompletionRequest) async throws -> Response {
        if request.stream == true {
            return try await streamingChatCompletionResponse(for: request)
        }

        do {
            try await generationGate.wait()
        } catch is CancellationError {
            return errorResponse("Request was cancelled.", status: .serviceUnavailable)
        }
        metrics.recordGenerationStarted()
        do {
            let backend = try await validatedBackend(for: request)
            let boundedRequest = try boundedForOutputCap(request)
            var response: ChatCompletionResponse
            if let generationTimeout = configuration.generationTimeout {
                response = try await ServerGenerationTimeout.run(
                    generationTimeout,
                    operation: { try await adapter.response(for: boundedRequest, using: backend) },
                    onTimeout: { [canCancelInFlightGenerationOnTimeout] in
                        if canCancelInFlightGenerationOnTimeout { backend.stopGeneration() }
                    }
                )
            } else {
                response = try await adapter.response(for: boundedRequest, using: backend)
            }
            response = correctedForOutputCapTruncation(response, effectiveMaxTokens: boundedRequest.maxCompletionTokens)
            await generationGate.signal()
            metrics.recordGenerationCompleted(tokenCount: tokenCount(in: response.contentText))
            return jsonResponse(response)
        } catch {
            await generationGate.signal()
            metrics.recordGenerationFailed()
            throw error
        }
    }

    /// Clamps the client-requested output-token ceiling to
    /// `configuration.maxGenerationOutputTokens`, and supplies that ceiling
    /// outright when the request specifies neither `max_tokens` nor
    /// `max_completion_tokens`. See that property's doc comment for why an
    /// unset request field is otherwise an unbounded-output hazard (#2265).
    ///
    /// Throws `.invalidRequest` (HTTP 400, matching OpenAI's own behavior)
    /// for a non-positive `max_tokens`/`max_completion_tokens` rather than
    /// silently clamping it — `min(0, ceiling)` would otherwise flow through
    /// as a "successful" 200 response with an empty completion, which is a
    /// confusing way to reject a malformed request.
    private func boundedForOutputCap(_ request: ChatCompletionRequest) throws -> ChatCompletionRequest {
        let requested = request.maxCompletionTokens ?? request.maxTokens
        if let requested, requested <= 0 {
            throw ServerError.invalidRequest(
                message: "max_tokens/max_completion_tokens must be a positive integer.",
                param: "max_tokens",
                code: "invalid_max_tokens"
            )
        }
        guard let ceiling = configuration.maxGenerationOutputTokens else { return request }
        var bounded = request
        bounded.maxCompletionTokens = min(requested ?? ceiling, ceiling)
        bounded.maxTokens = nil
        return bounded
    }

    /// Rewrites `.stop` to `.length` when the response was very likely
    /// truncated by `effectiveMaxTokens` (the ceiling actually passed to
    /// generation on this request — see `boundedForOutputCap`).
    ///
    /// `ChatCompletionEventMapper`'s `Accumulator.finishReason` (in
    /// `ChatCompletionsAdapter.swift`) only ever reports `.toolCalls` or
    /// `.stop` — it has no way to know the output-token cap actually ended
    /// generation, since `InferenceBackend.generate(...)`'s event stream
    /// doesn't surface a distinct "hit max tokens" stop reason at this
    /// layer. Left uncorrected, a client that omits `max_tokens` and gets
    /// cut off at the server's default ceiling would be told the model
    /// stopped naturally — a lie the cap must not tell now that it's
    /// default-on (#2265 review).
    ///
    /// Prefers the backend-reported `usage.completionTokens` (exact) when
    /// present; falls back to the same whitespace-based token estimate used
    /// elsewhere in this file (`tokenCount(in:)`) when `usage` is absent —
    /// approximate, but the only signal available without a real
    /// `InferenceBackend` stop-reason contract.
    private func correctedForOutputCapTruncation(
        _ response: ChatCompletionResponse,
        effectiveMaxTokens: Int?
    ) -> ChatCompletionResponse {
        guard let effectiveMaxTokens else { return response }
        guard var choice = response.choices.first, choice.finishReason == .stop else { return response }
        let completionTokens = response.usage?.completionTokens ?? tokenCount(in: response.contentText)
        guard completionTokens >= effectiveMaxTokens else { return response }
        choice.finishReason = .length
        var corrected = response
        corrected.choices[0] = choice
        return corrected
    }

    /// Streaming counterpart to `correctedForOutputCapTruncation(_:effectiveMaxTokens:)`
    /// — same correction (`.stop` → `.length`), applied per-chunk as each one
    /// is about to be written, since streaming has no single terminal
    /// response to patch after the fact. Uses `cumulativeTokenCount` (the
    /// running whitespace-based token estimate `writeSSEChunks` already
    /// maintains) rather than backend-reported usage, since a streaming
    /// client rarely sets `stream_options.include_usage` and usage — even
    /// when present — normally arrives in its own trailing chunk, after the
    /// finish-reason chunk this needs to correct.
    private static func correctedChunkForOutputCapTruncation(
        _ chunk: ChatCompletionChunk,
        cumulativeTokenCount: Int,
        effectiveMaxTokens: Int?
    ) -> ChatCompletionChunk {
        guard let effectiveMaxTokens, cumulativeTokenCount >= effectiveMaxTokens else { return chunk }
        guard chunk.choices.contains(where: { $0.finishReason == .stop }) else { return chunk }
        var corrected = chunk
        corrected.choices = chunk.choices.map { choice in
            var choice = choice
            if choice.finishReason == .stop {
                choice.finishReason = .length
            }
            return choice
        }
        return corrected
    }

    private func streamingChatCompletionResponse(for request: ChatCompletionRequest) async throws -> Response {
        do {
            try await generationGate.wait()
        } catch is CancellationError {
            return errorResponse("Request was cancelled.", status: .serviceUnavailable)
        }
        metrics.recordGenerationStarted()

        let backend: any InferenceBackend
        let boundedRequest: ChatCompletionRequest
        do {
            backend = try await validatedBackend(for: request)
            boundedRequest = try boundedForOutputCap(request)
        } catch {
            await generationGate.signal()
            metrics.recordGenerationFailed()
            throw error
        }

        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        headers[.connection] = "keep-alive"
        headers[HTTPField.Name("X-Accel-Buffering")!] = "no"

        let idleTimeout = configuration.streamingIdleTimeout
        let canCancel = canCancelInFlightGenerationOnTimeout

        let body = ResponseBody { writer in
            do {
                let chunks = try adapter.chunks(for: boundedRequest, using: backend)
                let streamedTokenCount = try await writeSSEChunks(
                    chunks,
                    to: &writer,
                    encoder: JSONEncoder(),
                    idleTimeout: idleTimeout,
                    effectiveMaxTokens: boundedRequest.maxCompletionTokens,
                    onIdleTimeout: { if canCancel { backend.stopGeneration() } }
                ) { chunk in tokenCount(in: chunk) }
                metrics.recordGenerationCompleted(tokenCount: streamedTokenCount)
                await generationGate.signal()
            } catch {
                metrics.recordGenerationFailed()
                await generationGate.signal()
                throw error
            }
        }

        return Response(status: .ok, headers: headers, body: body)
    }

    /// Writes one SSE `data: <json>\n\n` frame per chunk followed by the
    /// `[DONE]` sentinel, reusing a single ``ByteBuffer`` across tokens and
    /// writing the encoder's bytes straight in — no `Data` -> `String` ->
    /// interpolated-`String` -> fresh-`ByteBuffer` round trip per token (#2269).
    ///
    /// Each chunk is still written (and flushed to the wire by Hummingbird)
    /// individually: this must never become buffer-then-flush-at-end, since
    /// incremental per-token delivery is `ManifoldServer`'s whole
    /// differentiator over batching servers. `SSEStreamWritingTests` pins that
    /// behavior by asserting the first frame lands before the source stream
    /// finishes producing tokens.
    ///
    /// Extracted as a free function — rather than inlined in the
    /// `ResponseBody` closure — so that regression test can drive it directly
    /// with a fake writer and a paced fake token stream, without spinning up a
    /// full Hummingbird request.
    ///
    /// `idleTimeout` (default `nil`, preserving the pre-#2265 unbounded
    /// behavior for direct callers/tests that don't pass it) re-arms every
    /// time a new chunk is read from `chunks` (i.e. produced by the
    /// backend/adapter) — NOT when it is subsequently written to `writer`; a
    /// stalled *reader* on a healthy stream is not covered. See
    /// `ServerConfiguration.streamingIdleTimeout`'s doc comment for why this
    /// is idle-reset rather than a wall-clock cap. On expiry, `onIdleTimeout`
    /// is invoked (real `InferenceBackend.stopGeneration()` cancellation when
    /// the caller's closure allows it — see
    /// `ServerApp.canCancelInFlightGenerationOnTimeout` — otherwise mere task
    /// abandonment), one terminal SSE `data:` frame carrying a
    /// `generation_timeout` error envelope is written so the client sees a
    /// well-formed end to the stream, and this then throws
    /// `ServerError.generationTimedOut` so the caller's existing
    /// metrics/`generationGate` error path runs.
    ///
    /// `effectiveMaxTokens` (default `nil`), when set, corrects a terminal
    /// chunk's `finishReason` from `.stop` to `.length` once the running
    /// token estimate reaches it — see `correctedForOutputCapTruncation`'s
    /// doc comment for why `ChatCompletionEventMapper` can't report this
    /// itself.
    internal func writeSSEChunks(
        _ chunks: AsyncThrowingStream<ChatCompletionChunk, Error>,
        to writer: inout any ResponseBodyWriter,
        encoder: JSONEncoder,
        idleTimeout: Duration? = nil,
        effectiveMaxTokens: Int? = nil,
        onIdleTimeout: @escaping @Sendable () -> Void = {},
        tokenCount: (ChatCompletionChunk) -> Int
    ) async throws -> Int {
        var streamedTokenCount = 0
        var buffer = ByteBuffer()

        func writeChunk(_ chunk: ChatCompletionChunk) throws {
            streamedTokenCount += tokenCount(chunk)
            let corrected = Self.correctedChunkForOutputCapTruncation(
                chunk,
                cumulativeTokenCount: streamedTokenCount,
                effectiveMaxTokens: effectiveMaxTokens
            )
            buffer.clear()
            buffer.writeStaticString("data: ")
            buffer.writeBytes(try encoder.encode(corrected))
            buffer.writeStaticString("\n\n")
        }

        guard let idleTimeout else {
            for try await chunk in chunks {
                try writeChunk(chunk)
                try await writer.write(buffer)
            }
            try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
            return streamedTokenCount
        }

        let outcomes = ServerIdleTimeoutPuller.make(chunks, idleTimeout: idleTimeout)
        for await outcome in outcomes {
            switch outcome {
            case .element(let chunk):
                try writeChunk(chunk)
                try await writer.write(buffer)
            case .finished:
                try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
                return streamedTokenCount
            case .failure(let error):
                throw error
            case .timedOut:
                onIdleTimeout()
                let timeoutMessage = "Generation exceeded the configured idle timeout of \(idleTimeout)."
                let envelope = ChatCompletionErrorEnvelope(
                    message: timeoutMessage,
                    type: "server_error",
                    code: "generation_timeout"
                )
                buffer.clear()
                buffer.writeStaticString("data: ")
                buffer.writeBytes(try encoder.encode(envelope))
                buffer.writeStaticString("\n\n")
                try await writer.write(buffer)
                throw ServerError.generationTimedOut(timeoutMessage)
            }
        }
        // Unreachable in practice: `ServerIdleTimeoutPuller.make` always
        // yields exactly one terminal `Outcome` (`.finished`/`.failure`/
        // `.timedOut`) — each handled above with a `return`/`throw` — before
        // finishing the underlying `AsyncStream`. This satisfies the
        // compiler's exhaustiveness requirement for the `-> Int` return type.
        throw ServerError.generationFailed("Streaming chunk source ended without a terminal outcome.")
    }

    /// Decodes a request body, mapping decode/parse failures to a 400
    /// `invalid_request_error` instead of letting them fall through to the
    /// generic 500 `server_error` path.
    ///
    /// A malformed JSON body is a client mistake, not a server fault. We catch
    /// `DecodingError` (and any non-`ServerError` thrown while decoding the
    /// body) and rethrow it as ``ServerError/invalidRequest(message:param:code:)``
    /// — the existing path that already produces a correct 400 envelope. The
    /// surfaced message is a readable summary, never a raw `String(describing:)`
    /// dump of internal Swift type detail.
    private func decodeBody<T: Decodable>(
        _ type: T.Type,
        from request: Request,
        context: ManifoldServerRequestContext
    ) async throws -> T {
        do {
            return try await request.decode(as: type, context: context)
        } catch let error as ServerError {
            // A capability/validation error raised during decoding already
            // carries the right shape — let it through unchanged.
            throw error
        } catch let error as DecodingError {
            throw ServerError.invalidRequest(
                message: "Could not parse request body: \(Self.readableDecodingFailure(error))",
                code: "invalid_body"
            )
        } catch {
            throw ServerError.invalidRequest(
                message: "Could not parse request body. Ensure it is valid JSON matching the expected schema.",
                code: "invalid_body"
            )
        }
    }

    /// Renders a `DecodingError` as a short, client-safe explanation. We expose
    /// the coding path and the human-readable debug description, but never the
    /// underlying error chain or Swift type names.
    private static func readableDecodingFailure(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }
            return keys.isEmpty ? "" : " at '\(keys.joined(separator: "."))'"
        }
        switch error {
        case .dataCorrupted(let context):
            return "malformed JSON\(path(context))."
        case .keyNotFound(let key, let context):
            return "missing required field '\(key.stringValue)'\(path(context))."
        case .typeMismatch(_, let context):
            return "wrong type for field\(path(context))."
        case .valueNotFound(_, let context):
            return "missing value for field\(path(context))."
        @unknown default:
            return "the body did not match the expected schema."
        }
    }

    private func validatedBackend(for request: ChatCompletionRequest) async throws -> any InferenceBackend {
        let backend = try await backendProvider.backend(for: ServerBackendRequest(model: request.model))
        try validateRequestCapabilities(for: request, backend: backend)
        return backend
    }

    private func validateRequestCapabilities(for request: ChatCompletionRequest, backend: any InferenceBackend) throws {
        let capabilities = backend.capabilities
        let unsupportedCode = "unsupported_capability"

        if request.messages.contains(where: { $0.role == .system || $0.role == .developer }),
           !capabilities.supportsSystemPrompt {
            throw ServerError.invalidRequest(
                message: "This backend does not support system or developer messages; remove those messages or choose a backend with system-prompt support.",
                param: "messages",
                code: unsupportedCode
            )
        }

        if request.tools?.isEmpty == false, !capabilities.supportsToolCalling {
            throw ServerError.invalidRequest(
                message: "This backend does not support tool calling; remove tools or choose a tool-capable backend.",
                param: "tools",
                code: unsupportedCode
            )
        }

        if let toolChoice = request.toolChoice,
           toolChoice.requiresToolCalling,
           !capabilities.supportsToolCalling {
            throw ServerError.invalidRequest(
                message: "This backend does not support tool_choice values that require tool calling; remove tool_choice or choose a tool-capable backend.",
                param: "tool_choice",
                code: unsupportedCode
            )
        }

        switch request.responseFormat?.type {
        case .jsonObject:
            if !capabilities.supportsNativeJSONMode {
                throw ServerError.invalidRequest(
                    message: "response_format json_object requires a backend that supports native JSON mode.",
                    param: "response_format",
                    code: unsupportedCode
                )
            }
        case .jsonSchema:
            if !capabilities.supportsStructuredOutput {
                throw ServerError.invalidRequest(
                    message: "response_format json_schema requires a backend that supports structured output.",
                    param: "response_format",
                    code: unsupportedCode
                )
            }
        case .text, .none:
            break
        }
    }

    private func httpStatus(for error: Error) -> HTTPResponse.Status {
        // A decode failure is a malformed client request, not a server fault —
        // surface 400 even on the rare path that doesn't route through
        // `decodeBody`.
        if error is DecodingError {
            return .badRequest
        }
        guard let serverError = error as? ServerError else {
            return .internalServerError
        }
        switch serverError {
        case .invalidRequest:
            return .badRequest
        case .backendUnavailable:
            return .serviceUnavailable
        case .invalidConfiguration, .notImplemented, .generationFailed:
            return .internalServerError
        case .generationTimedOut:
            return .gatewayTimeout
        }
    }

    private func metricsResponse() -> Response {
        let snapshot = metrics.snapshot()
        let body = """
        # TYPE basechat_requests_total counter
        basechat_requests_total \(snapshot.requests)
        # TYPE basechat_generations_in_flight gauge
        basechat_generations_in_flight \(snapshot.inFlightGenerations)
        # TYPE basechat_completions_total counter
        basechat_completions_total \(snapshot.completions)
        # TYPE basechat_failures_total counter
        basechat_failures_total \(snapshot.failures)
        # TYPE basechat_tokens_total counter
        basechat_tokens_total \(snapshot.tokens)

        """
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; version=0.0.4; charset=utf-8"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: body)))
    }

    private func tokenCount(in content: String) -> Int {
        content.split(whereSeparator: \.isWhitespace).count
    }

    private func tokenCount(in chunk: ChatCompletionChunk) -> Int {
        chunk.choices.reduce(0) { count, choice in
            count + tokenCount(in: choice.delta.content ?? "")
        }
    }
}

private extension ChatCompletionToolChoice {
    var requiresToolCalling: Bool {
        switch self {
        case .function, .required:
            return true
        case .auto, .none:
            return false
        }
    }
}

#endif
