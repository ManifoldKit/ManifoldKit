import Foundation
import ManifoldInference

/// Maps an ``MCPError`` to the framework's unified ``ToolResult/ErrorKind``.
///
/// Used by ``MCPToolExecutor`` (and any future MCP-aware dispatch site) so that
/// MCP tool failures surface to backends and orchestrators with the same
/// taxonomy as native tool errors. Without this mapping, MCP failures would be
/// second-class citizens: the model would see only a string, not a typed
/// failure class it can reason about.
///
/// The switch is intentionally exhaustive — there is no `default:` clause —
/// so adding a new ``MCPError`` case forces a compile error here, prompting
/// the author to choose the right ``ToolResult/ErrorKind`` rather than
/// silently inheriting `.permanent`.
package func errorKind(for error: MCPError) -> ToolResult.ErrorKind {
    switch error {
    case .toolNotFound:
        return .unknownTool
    case .requestTimeout:
        return .timeout
    case .cancelled:
        return .cancelled
    case .authorizationRequired,
         .authorizationFailed,
         .unauthorized:
        return .permissionDenied
    case .transportClosed,
         .transportFailure,
         .networkUnavailable,
         .backgroundedDuringDispatch:
        return .transient
    case .protocolError(let code, _, _):
        // JSON-RPC reserved error codes carry stable semantics:
        //   -32601 Method not found  → caller named a tool the server doesn't expose
        //   -32602 Invalid params    → arguments failed schema/type checking
        // Anything else is a server-side failure with no recovery path the
        // model can act on, so report it as permanent.
        switch code {
        case -32601:
            return .unknownTool
        case -32602:
            return .invalidArguments
        default:
            return .permanent
        }
    case .unsupportedProtocolVersion,
         .malformedMetadata,
         .issuerMismatch,
         .dcrFailed,
         .ssrfBlocked,
         .tooManyTools,
         .oversizeContent,
         .oversizeMessage,
         .failed:
        // No clean ErrorKind match exists for these — they are protocol or
        // configuration-level failures that the model cannot recover from by
        // adjusting its arguments. Treat as .permanent until PR-F introduces
        // a richer taxonomy. Do NOT add a new ErrorKind case here.
        return .permanent
    }
}
