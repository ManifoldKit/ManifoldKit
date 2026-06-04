import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ChatViewModel + WebSearch
//
// Host-facing entry surface for `WebSearchRuntime`. Mirrors the role
// `ChatViewModel+ImageGeneration` / `ChatViewModel+VideoGeneration` play for
// their runtimes: forwards the command to the runtime and surfaces the result.
//
// Unlike image/video, web search is request/response — it returns the result
// text to the caller (so the conversation turn can hand it back to the model)
// rather than inserting a placeholder message and driving an event stream.
// There is therefore no event-drain task and no progress dictionary.
//
// The runtime is **optional** — chat-only hosts never call
// `configure(webSearchRuntime:)` and `searchWeb(query:)` throws
// `.notConfigured`. The text path on `ChatViewModel` is unchanged.

/// Errors thrown by ``ChatViewModel`` web-search entry methods.
public enum ChatViewModelWebSearchError: Error, LocalizedError, Equatable {

    /// ``ChatViewModel/configure(webSearchRuntime:)`` was never called.
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Web search is not configured. Install a WebSearchRuntime via configure(webSearchRuntime:)."
        }
    }
}

@MainActor
extension ChatViewModel {

    // MARK: - Runtime install

    /// The web-search runtime, if the host wired one up. `nil` for chat-only
    /// hosts; ``searchWeb(query:)`` throws
    /// ``ChatViewModelWebSearchError/notConfigured`` in that case.
    public var webSearchRuntime: (any WebSearchRuntime)? {
        _webSearchRuntime
    }

    /// Install a ``WebSearchRuntime``. Typically called by
    /// ``ManifoldBootstrap`` when the host opts in to web search; app code can
    /// also call it directly.
    ///
    /// The view model holds the runtime strongly for the rest of its lifetime —
    /// same ownership model as ``imageRuntime`` / ``videoRuntime``. There is no
    /// event-drain task to restart because web search is request/response.
    public func configure(webSearchRuntime: any WebSearchRuntime) {
        _webSearchRuntime = webSearchRuntime
    }

    // MARK: - Commands

    /// Run a web search and return the result text.
    ///
    /// Forwards to the installed ``WebSearchRuntime``. The result is returned
    /// so the caller (typically ``WebSearchToolSource``) can hand it back to
    /// the model inside the same conversation turn.
    ///
    /// - Parameter query: The search query. Empty-query validation happens at
    ///   the tool boundary.
    /// - Returns: The search result text.
    /// - Throws: ``ChatViewModelWebSearchError/notConfigured`` if no runtime is
    ///   installed, or any provider/network error thrown by the runtime.
    public func searchWeb(query: String) async throws -> String {
        guard let runtime = _webSearchRuntime else {
            throw ChatViewModelWebSearchError.notConfigured
        }
        return try await runtime.search(query: query)
    }
}
