#if Server
import Foundation
import Hummingbird

/// The `/v1/models` response envelope. `public` because `Model`'s owning
/// namespace has to be as visible as `Model` itself for
/// `ServerBackendProvider.listModelRecords()` (public) to reference
/// `[ModelsListResponse.Model]`.
public struct ModelsListResponse: Codable, Equatable, Sendable {
    /// Public (v0.71+): the return element of ``ServerBackendProvider/listModelRecords()``
    /// — the seam a host-injected provider vends its model catalog through.
    public struct Model: Codable, Equatable, Sendable {
        public var id: String
        public var object: String
        public var created: Int
        public var ownedBy: String
        public var status: String?
        public var backend: String?
        public var source: String?
        public var current: Bool?

        public init(
            id: String,
            object: String = "model",
            created: Int = 0,
            ownedBy: String = "manifold",
            status: String? = nil,
            backend: String? = nil,
            source: String? = nil,
            current: Bool? = nil
        ) {
            self.id = id
            self.object = object
            self.created = created
            self.ownedBy = ownedBy
            self.status = status
            self.backend = backend
            self.source = source
            self.current = current
        }

        private enum CodingKeys: String, CodingKey {
            case id, object, created, status, backend, source, current
            case ownedBy = "owned_by"
        }
    }

    internal var object: String
    internal var data: [Model]

    internal init(models: [String]) {
        self.init(modelRecords: models.map { Model(id: $0) })
    }

    internal init(modelRecords: [Model]) {
        self.object = "list"
        self.data = modelRecords
    }
}

internal func jsonResponse(
    _ value: some Encodable,
    status: HTTPResponse.Status = .ok
) -> Response {
    do {
        let data = try JSONEncoder().encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    } catch {
        let body = #"{"error":{"message":"Failed to encode server response.","type":"server_error","param":null,"code":"encoding_failed"}}"#
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        return Response(status: .internalServerError, headers: headers, body: .init(byteBuffer: ByteBuffer(string: body)))
    }
}

internal func errorResponse(
    _ message: String,
    status: HTTPResponse.Status,
    type: String = "server_error",
    code: String? = nil
) -> Response {
    jsonResponse(ChatCompletionErrorEnvelope(message: message, type: type, code: code), status: status)
}

#endif
