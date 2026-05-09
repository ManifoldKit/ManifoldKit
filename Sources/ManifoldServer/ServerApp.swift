#if Server
import ManifoldInference
import Foundation
import Hummingbird
import HTTPTypes

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
        let router = Router()
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
                let completionRequest = try await request.decode(as: ChatCompletionRequest.self, context: context)
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

    private func corsMiddleware() -> CORSMiddleware<BasicRequestContext> {
        let allowOrigin: CORSMiddleware<BasicRequestContext>.AllowOrigin
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
        if let serverError = error as? ServerError, case .invalidRequest = serverError {
            return .badRequest
        }
        return .internalServerError
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
