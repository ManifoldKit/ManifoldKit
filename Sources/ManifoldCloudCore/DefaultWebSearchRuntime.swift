import Foundation
import ManifoldInference
import ManifoldRuntime

/// Concrete ``WebSearchRuntime`` backed by an OpenAI-Chat-Completions-shaped
/// search endpoint (e.g. xAI's `grok` search models).
///
/// Performs the actual HTTP call that used to live inside
/// `WebSearchToolSource`: a POST to `<baseURL>/chat/completions` with a
/// `search_parameters` field, `Bearer` auth via a ``TokenProvider``, routed
/// through `URLSessionFactory.ephemeral()`. Lives in `ManifoldCloudCore`
/// (relocated from the retired `ManifoldCloud` shim in P7) because
/// that is the layer where cloud SDK weight and direct network I/O belong (and
/// where the ``TrafficBoundaryAuditTest`` network-I/O allowlist covers cloud
/// backends); the UI and runtime layers depend only on the abstract
/// ``WebSearchRuntime`` port.
///
/// Configure with your provider's base URL and a ``TokenProvider`` for auth:
/// ```swift
/// let runtime = DefaultWebSearchRuntime(
///     baseURL: "https://api.x.ai/v1",
///     tokenProvider: myProvider
/// )
/// viewModel.configure(webSearchRuntime: runtime)
/// ```
@MainActor
public final class DefaultWebSearchRuntime: WebSearchRuntime {

    private let baseURL: String
    private let tokenProvider: any TokenProvider
    private let model: String
    private let urlSession: URLSession

    public init(
        baseURL: String,
        tokenProvider: any TokenProvider,
        model: String = "grok-4.3",
        session: URLSession = URLSessionFactory.ephemeral()
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.model = model
        self.urlSession = session
    }

    public func search(query: String) async throws -> String {
        let token = try await tokenProvider.token()
        // Safe URL construction (#1558): never force-unwrap a URL built from a
        // host-supplied base string.
        guard let endpointURL = URL(string: "\(baseURL)/chat/completions") else {
            throw WebSearchRuntimeError.invalidBaseURL(baseURL)
        }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": query]],
            "search_parameters": ["mode": "on"],
            "max_tokens": 1000
        ])

        let (responseData, response) = try await ConnectAddressPinningDelegate.pinnedData(for: request, on: urlSession)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode
        guard httpStatus == 200 else {
            throw WebSearchRuntimeError.httpFailure(status: httpStatus)
        }
        // `try?` here is audit-approved optional decoding at a trust boundary:
        // a malformed provider response degrades to "No results" rather than
        // throwing, matching the pre-refactor behaviour.
        let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        let content = ((responseJSON?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? "No results"
        return content
    }
}

/// Errors surfaced by ``DefaultWebSearchRuntime``. The web-search tool maps
/// these onto a ``ToolResult`` with the appropriate `errorKind` so the model
/// receives a readable failure rather than an opaque trap.
public enum WebSearchRuntimeError: Error, LocalizedError, Equatable {

    /// The configured base URL could not be composed into a valid endpoint URL.
    case invalidBaseURL(String)

    /// The search endpoint returned a non-200 status (or no HTTP response).
    case httpFailure(status: Int?)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let baseURL):
            return "Invalid baseURL: \(baseURL)"
        case .httpFailure(let status):
            return "Search failed (HTTP \(status.map(String.init) ?? "unknown"))"
        }
    }
}
