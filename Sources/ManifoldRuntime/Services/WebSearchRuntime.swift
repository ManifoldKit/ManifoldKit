import Foundation
import ManifoldInference

// MARK: - WebSearchRuntime
//
// Sibling port to `ImageGenerationRuntime` / `VideoGenerationRuntime` for the
// web-search path. Unlike image/video — which insert a placeholder message and
// drive a long-running event stream — web search is a synchronous
// request/response: the tool needs the search result *returned* so it can be
// handed back to the model inside the same conversation turn.
//
// Because the result flows back to the model (rather than being persisted as a
// `.generatedImage`/`.generatedVideo` part), this port is a thin protocol with
// a single `search(query:)` method rather than a service-holding class with an
// `events` stream. The shape still mirrors the sibling runtimes' role: an
// abstraction in `ManifoldRuntime` whose concrete implementation lives above
// the UI layer (in `ManifoldCloud`, where network I/O is allowlisted).
//
// `ManifoldRuntime` imports only `ManifoldInference`, so this port must not
// reference `TokenProvider` (ManifoldCloudCore) or `URLSession` — the concrete
// `DefaultWebSearchRuntime` in `ManifoldCloud` owns all of that.

/// Performs a web search and returns the result text to the caller.
///
/// Sibling to ``ImageGenerationRuntime`` and ``VideoGenerationRuntime``, but
/// modelled as a protocol because web search is request/response: the result
/// is returned so the conversation turn can hand it back to the model, rather
/// than persisted as a message part.
///
/// The concrete implementation (`DefaultWebSearchRuntime`) lives in
/// `ManifoldCloud`, which is on the network-I/O allowlist and can import
/// ``TokenProvider`` and `URLSession`. UI and runtime layers depend only on
/// this abstraction.
@MainActor
public protocol WebSearchRuntime: AnyObject, Sendable {

    /// Runs a web search for `query` and returns the result text.
    ///
    /// - Parameter query: The user/model-supplied search query. Callers should
    ///   pass a non-empty, trimmed query; validation of empty input happens at
    ///   the tool boundary.
    /// - Returns: The search result text to surface back to the model.
    /// - Throws: Provider/network errors (auth, transient HTTP failures,
    ///   malformed responses). The tool boundary maps these to a
    ///   ``ToolResult`` with an appropriate `errorKind`.
    func search(query: String) async throws -> String
}
