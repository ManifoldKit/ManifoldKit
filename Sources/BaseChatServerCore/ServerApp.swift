import BaseChatInference
import Foundation
import Hummingbird
import HTTPTypes

package struct ServerHealth: Codable, Equatable, Sendable {
    package var status: String

    package init(status: String = "ok") {
        self.status = status
    }
}

package struct ServerApp: Sendable {
    package var configuration: ServerConfiguration
    package var backendProvider: any ServerBackendProvider
    package var adapter: any ChatCompletionsAdapter
    package var metrics: ServerMetrics
    package var generationGate: AsyncSemaphore

    package init(
        configuration: ServerConfiguration = ServerConfiguration(),
        backendProvider: any ServerBackendProvider = UnavailableServerBackendProvider(),
        adapter: any ChatCompletionsAdapter = DefaultChatCompletionsAdapter(),
        metrics: ServerMetrics = ServerMetrics()
    ) {
        self.configuration = configuration
        self.backendProvider = backendProvider
        self.adapter = adapter
        self.metrics = metrics
        self.generationGate = AsyncSemaphore(value: configuration.parallelSlots)
    }

    package func health() -> ServerHealth { ServerHealth() }

    package func makeApplication() -> some ApplicationProtocol {
        let router = Router()
        router.add(middleware: corsMiddleware())

        router.get("/health") { _, _ in
            jsonResponse(health())
        }

        router.get("/v1/models") { request, _ in
            if let unauthorized = authorizationFailure(for: request) {
                return unauthorized
            }
            metrics.recordRequestStarted()
            do {
                let models = try await backendProvider.listModels()
                metrics.recordRequestCompleted()
                return jsonResponse(ModelsListResponse(models: models))
            } catch {
                metrics.recordFailure()
                metrics.recordRequestCompleted()
                return errorResponse(String(describing: error), status: .internalServerError)
            }
        }

        router.post("/v1/chat/completions") { request, context in
            if let unauthorized = authorizationFailure(for: request) {
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
                return errorResponse(String(describing: error), status: .internalServerError)
            }
        }

        if configuration.metricsEnabled {
            router.get("/metrics") { _, _ in
                metricsResponse()
            }
        }

        let appConfiguration = ApplicationConfiguration(
            address: .hostname(configuration.host, port: configuration.port),
            serverName: "BaseChatServer"
        )
        return Application(router: router, configuration: appConfiguration)
    }

    package func run() async throws {
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

    private func authorizationFailure(for request: Request) -> Response? {
        guard let apiKey = configuration.apiKey, !apiKey.isEmpty else { return nil }
        let expected = "Bearer \(apiKey)"
        guard request.headers[.authorization] == expected else {
            return errorResponse(
                "Missing or invalid bearer token.",
                status: .unauthorized,
                type: "invalid_request_error",
                code: "invalid_api_key"
            )
        }
        return nil
    }

    private func chatCompletionResponse(for request: ChatCompletionRequest) async throws -> Response {
        if request.stream == true {
            return try await streamingChatCompletionResponse(for: request)
        }

        await generationGate.wait()
        metrics.recordGenerationStarted()
        do {
            let backend = try await backendProvider.backend(for: ServerBackendRequest(model: request.model))
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
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        headers[.connection] = "keep-alive"
        headers[HTTPField.Name("X-Accel-Buffering")!] = "no"

        let body = ResponseBody { writer in
            await generationGate.wait()
            metrics.recordGenerationStarted()
            var streamedTokenCount = 0
            do {
                let backend = try await backendProvider.backend(for: ServerBackendRequest(model: request.model))
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
