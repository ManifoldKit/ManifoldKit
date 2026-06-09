import Foundation

/// Composition root for in-process (non-HTTP) inference backends.
///
/// `LocalInferenceAdapter` is the local-backend analog of
/// `CloudHTTPProviderAdapter`. Where the cloud adapter composes wire-protocol
/// witnesses (framed transport, stream finalizer, payload handler, …) so a
/// single envelope (`SSECloudBackend`) can drive every cloud provider,
/// `LocalInferenceAdapter` composes the small set of *behavioural* witnesses
/// that the two in-process families (`MLXGenerationDriver`,
/// `LlamaGenerationDriver`) actually share:
///
/// - The label used by drift-guard diagnostics.
/// - The tool-call wire shape (inline XML markers in both current families,
///   but pinned as a witness so a future C-API backend with a structured
///   tool-call channel slots in without copy-paste).
/// - The thinking-marker strategy (whether the driver runs `ThinkingTransform`
///   eagerly, off-by-default, or never).
/// - The static `BackendCapabilities` payload its owning backend declares —
///   pulled onto the adapter so `LocalBackendRealDriverCoverageTest` can
///   probe "what does this backend claim?" without instantiating the full
///   backend.
///
/// **What this protocol deliberately omits**: a unified `run(...)` method.
/// The two existing drivers run on fundamentally different surfaces
/// (`llama_context *` + raw `llama_token[]` for the C-ABI llama.cpp driver
/// vs. `MLXPreparedInput` + `MLXPromptCache` for the Swift MLX driver). A
/// generic `run` would either need an associated `Input` type — which
/// defeats the witness-composition pattern the cloud adapter follows — or
/// would have to be wrapped in a type-erased box that nothing on the call
/// path needs. The cloud adapter solves this by routing every backend
/// through one envelope (`SSECloudBackend`); local backends each own their
/// runtime envelope (`MLXBackend`, `LlamaBackend`) and call their driver
/// directly. Cross-driver behaviour parity is enforced by the contract
/// suite (`InferenceBackendContractTests`), not by a shared `run`
/// signature.
///
/// ### Sendability
///
/// Conformers must be value types with no shared mutable state. The two
/// shipping drivers are stateless `struct`s; the protocol's `Sendable`
/// constraint ensures any future conformer keeps that property.
public protocol LocalInferenceAdapter: Sendable {
    /// Human-readable label used by `LocalBackendRealDriverCoverageTest`
    /// and diagnostic logs. Convention: `"<family>.<driver-role>"`, e.g.
    /// `"mlx.generation"`, `"llama.generation"`.
    var adapterName: String { get }

    /// The wire shape this adapter uses for tool calls.
    ///
    /// Both currently-shipping local drivers parse `<tool_call>…</tool_call>`
    /// (and the Llama driver also handles `<|tool_call>…<|end_of_turn>`)
    /// inline from the decoded text stream — there is no separate transport
    /// channel for tool calls, unlike cloud providers that carry them as
    /// typed events in the SSE stream. The witness is still pinned so a
    /// future local backend with a typed tool-call channel can declare it
    /// without copy-paste.
    var toolCallShape: any LocalToolCallShape { get }

    /// The strategy this adapter uses to detect and emit thinking-token
    /// (`.thinkingToken`, `.thinkingCompleted`) events.
    var thinkingMarkerStrategy: LocalThinkingMarkerStrategy { get }

    /// The static capability payload the owning backend declares. Used by
    /// `LocalBackendRealDriverCoverageTest` to verify each claimed
    /// capability has at least one non-mock fixture exercising the real
    /// driver path.
    ///
    /// This is the same payload returned by the backend's
    /// `InferenceBackend.capabilities` property; the adapter publishes it
    /// so coverage gates can read it without booting the full backend.
    var declaredCapabilities: BackendCapabilities { get }
}

// MARK: - Tool-Call Shape

/// Local-backend tool-call wire shape.
///
/// Mirrors `ManifoldCloudCore.ToolCallShape` in spirit but lives in
/// `ManifoldInference` because `ManifoldInference` cannot depend on
/// `ManifoldCloudCore` (which is itself trait-gated). The two protocols are
/// deliberately structurally identical (a single `shapeName` requirement)
/// so a future refactor can unify them into a single `BackendToolCallShape`
/// witness without churn at call sites.
public protocol LocalToolCallShape: Sendable {
    /// Human-readable shape label. Used by the cross-backend drift-guard
    /// audit and by `LocalBackendRealDriverCoverageTest` diagnostics.
    var shapeName: String { get }
}

/// Inline `<tool_call>…</tool_call>` / `<|tool_call>…<|end_of_turn>` text
/// markers parsed from the decoded token stream. The wire shape used today
/// by both `LlamaGenerationDriver` and `MLXGenerationDriver`.
public struct InlineXMLToolCallMarkers: LocalToolCallShape {
    public init() {}
    public var shapeName: String { "local.inline-xml" }
}

// MARK: - Thinking Marker Strategy

/// How a local driver emits thinking-token events.
public enum LocalThinkingMarkerStrategy: Sendable, Equatable {
    /// The driver runs `ThinkingTransform` eagerly whenever markers are
    /// provided (either by caller override or load-time auto-detection)
    /// and `GenerationConfig.maxThinkingTokens != 0`. Both shipping
    /// drivers use this strategy.
    case eagerWhenMarkersPresent

    /// The driver never engages `ThinkingTransform` — every decoded chunk
    /// surfaces as `.token`. Reserved for future native-bridge backends
    /// (e.g. Apple Foundation Models) where the host SDK already exposes
    /// reasoning blocks as typed events.
    case never
}
