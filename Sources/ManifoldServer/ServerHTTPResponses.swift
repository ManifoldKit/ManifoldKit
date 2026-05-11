#if Server
import Foundation
import Hummingbird

internal struct ModelsListResponse: Codable, Equatable, Sendable {
    internal struct Model: Codable, Equatable, Sendable {
        internal var id: String
        internal var object: String
        internal var created: Int
        internal var ownedBy: String
        internal var status: String?
        internal var backend: String?
        internal var source: String?
        internal var current: Bool?

        internal init(
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
