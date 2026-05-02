#if Server
import Foundation
import Hummingbird

package struct ModelsListResponse: Codable, Equatable, Sendable {
    package struct Model: Codable, Equatable, Sendable {
        package var id: String
        package var object: String

        package init(id: String, object: String = "model") {
            self.id = id
            self.object = object
        }
    }

    package var object: String
    package var data: [Model]

    package init(models: [String]) {
        self.object = "list"
        self.data = models.map { Model(id: $0) }
    }
}

package func jsonResponse(
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

package func errorResponse(
    _ message: String,
    status: HTTPResponse.Status,
    type: String = "server_error",
    code: String? = nil
) -> Response {
    jsonResponse(ChatCompletionErrorEnvelope(message: message, type: type, code: code), status: status)
}

#endif
