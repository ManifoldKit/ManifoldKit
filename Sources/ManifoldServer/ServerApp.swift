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
            let response = try await adapter.response(for: request, using: backend)
            await generationGate.signal()
            metrics.recordGenerationCompleted(tokenCount: tokenCount(in: response.contentText))
            return jsonResponse(response)
        } catch {
            await generationGate.signal()
            metrics.recordGenerationFailed()
            throw error
        }
    }

    private func streamingChatCompletionResponse(for request: ChatCompletionRequest) async throws -> Response {
        do {
            try await generationGate.wait()
        } catch is CancellationError {
            return errorResponse("Request was cancelled.", status: .serviceUnavailable)
        }
        metrics.recordGenerationStarted()

        let backend: any InferenceBackend
        do {
            backend = try await validatedBackend(for: request)
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

        let body = ResponseBody { writer in
            var streamedTokenCount = 0
            do {
                let chunks = try adapter.chunks(for: request, using: backend)
                let encoder = JSONEncoder()
                for try await chunk in chunks {
                    streamedTokenCount += tokenCount(in: chunk)
                    let data = try encoder.encode(chunk)
                    let line = String(decoding: data, as: UTF8.self)
                    try await writer.write(ByteBuffer(string: "data: \(line)\n\n"))
                }
                try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
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
