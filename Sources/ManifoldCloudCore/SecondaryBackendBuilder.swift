import Foundation
import ManifoldInference

/// Builds a configured *secondary* cloud ``InferenceBackend`` from a saved
/// ``APIEndpointRecord`` plus a (typically rotating) ``TokenProvider``.
///
/// This factory exists so callers that need a second, independently-credentialed
/// cloud backend — e.g. a thinking-trim pass routed through a different
/// endpoint — can build one from a persisted endpoint record without
/// re-implementing the provider → `configure(...)` mapping that
/// `ModelLifecycleCoordinator.loadEndpointBackend` performs inline. The mapping
/// of *which* providers accept a token-provider credential is kept in lockstep
/// with that coordinator's keychain-configurable branch (claude, openAI,
/// openAIResponses, custom).
///
/// ### Why a factory closure rather than direct construction
///
/// The concrete SSE cloud backends (`ClaudeBackend`, `OpenAIBackend`,
/// `OpenAIResponsesBackend`, …) live in `ManifoldCloudSaaS`, which sits
/// **above** `ManifoldCloudCore` in the dependency graph. CloudCore therefore
/// cannot name — let alone instantiate — those types. The same constraint is
/// why the engine resolves cloud backends through a runtime-registered
/// `EndpointBackendFactory` closure rather than a `switch` over concrete types.
///
/// This builder mirrors that design: the caller supplies a `makeBackend`
/// closure (the SaaS layer, the umbrella, or a test) that produces the bare
/// backend for a provider; the builder owns the validation, URL parsing, and
/// the token-provider `configure(...)` call. The builder never constructs a
/// concrete backend itself.
public enum SecondaryBackendBuilder {

    /// Builds a configured cloud ``InferenceBackend`` from `endpoint`, wiring it
    /// to authenticate via `tokenProvider` (re-read on every request).
    ///
    /// - Parameters:
    ///   - endpoint: the persisted endpoint record (provider, base URL, model).
    ///   - tokenProvider: the rotating credential source installed via
    ///     ``SSECloudBackend/configure(baseURL:tokenProvider:modelName:)``.
    ///   - makeBackend: produces the bare backend for the endpoint's provider.
    ///     Supplied by the SaaS layer (or a test) because CloudCore cannot name
    ///     the concrete backend types — see the type-level discussion. Return
    ///     `nil` to signal "no backend available for this provider".
    /// - Returns: a configured backend for the token-provider-capable cloud
    ///   providers (claude, openAI, openAIResponses, custom), or `nil` when the
    ///   provider does not fit the token-provider cloud shape
    ///   (ollama / lmStudio use URL + model, no bearer token), when `endpoint`
    ///   is invalid, or when `makeBackend` returns a backend that is not an
    ///   ``SSECloudBackend``.
    public static func cloudBackend(
        for endpoint: APIEndpointRecord,
        tokenProvider: any TokenProvider,
        makeBackend: (APIProvider) -> (any InferenceBackend)?
    ) -> (any InferenceBackend)? {
        // ollama / lmStudio authenticate with URL + model, not a bearer token,
        // so a TokenProvider has nothing to bind to. Mirrors the
        // EndpointBackendURLModelConfigurable branch in loadEndpointBackend.
        switch endpoint.provider {
        case .claude, .openAI, .openAIResponses, .custom:
            break
        case .ollama, .lmStudio:
            return nil
        }

        let trimmed = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            Log.inference.error("SecondaryBackendBuilder: invalid base URL '\(trimmed, privacy: .public)' for provider \(endpoint.provider.rawValue, privacy: .public)")
            return nil
        }

        guard let backend = makeBackend(endpoint.provider) else {
            Log.inference.error("SecondaryBackendBuilder: no backend supplied for provider \(endpoint.provider.rawValue, privacy: .public)")
            return nil
        }

        // The token-provider configure path lives on SSECloudBackend. Cast
        // rather than introduce a new opt-in protocol: every cloud SaaS backend
        // already subclasses SSECloudBackend, and gating on the base class keeps
        // this builder free of any ManifoldCloudSaaS dependency.
        guard let sse = backend as? SSECloudBackend else {
            Log.inference.error("SecondaryBackendBuilder: \(String(describing: type(of: backend)), privacy: .public) is not an SSECloudBackend; cannot install a TokenProvider")
            return nil
        }

        sse.configure(
            baseURL: url,
            tokenProvider: tokenProvider,
            modelName: endpoint.modelName
        )
        return sse
    }
}
