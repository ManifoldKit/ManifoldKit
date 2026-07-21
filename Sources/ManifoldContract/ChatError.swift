import Foundation

/// Structured error surfaced from ChatViewModel to the UI layer.
///
/// Preserves the original error type and provides a recovery action
/// so the UI can show contextual buttons (retry, configure API key, etc.)
/// instead of raw error strings.
public struct ChatError: Identifiable, Sendable {
    public let id: UUID
    public let kind: Kind
    public let message: String
    public let underlyingError: (any Error)?
    public let recovery: Recovery?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        message: String,
        underlyingError: (any Error)? = nil,
        recovery: Recovery? = nil
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.underlyingError = underlyingError
        self.recovery = recovery
    }

    /// ## Vocabulary freeze (1.0)
    ///
    /// **The `Kind` vocabulary is frozen as of the 1.0 release.** The four
    /// cases above are the complete, stable set; adding a case is
    /// source-breaking for exhaustive `switch` statements, so new cases land
    /// only in a major (`feat!:`) release. Cross-module consumers should add
    /// an `@unknown default:` arm to stay resilient to a future major (see
    /// #2208).
    public enum Kind: Equatable, Sendable {
        case generation
        case persistence
        case configuration
        case memoryPressure
    }

    /// ## Vocabulary freeze (1.0)
    ///
    /// **The `Recovery` vocabulary is frozen as of the 1.0 release.** The four
    /// cases above are the complete, stable set every recovery-button
    /// consumer switches over; adding a case is source-breaking for
    /// exhaustive `switch` statements, so new cases land only in a major
    /// (`feat!:`) release. Cross-module consumers should add an
    /// `@unknown default:` arm to stay resilient to a future major (see
    /// #2208).
    public enum Recovery: Equatable, Sendable {
        case retry
        case configureAPIKey
        case selectModel
        case dismissOnly
    }

    /// Derives a ChatError from a backend error with appropriate recovery action.
    public static func from(
        _ error: any Error,
        kind: Kind,
        context: String? = nil
    ) -> ChatError {
        let recovery: Recovery?
        if let backendError = error as? any BackendError {
            if backendError.isRetryable {
                recovery = .retry
            } else if let cloud = error as? CloudBackendError {
                switch cloud {
                case .authenticationFailed, .missingAPIKey:
                    recovery = .configureAPIKey
                default:
                    recovery = .dismissOnly
                }
            } else if let inference = error as? InferenceError {
                switch inference {
                case .modelNotFound, .memoryInsufficient:
                    recovery = .selectModel
                case .contextExhausted:
                    // The conversation exceeds the model's context window.
                    // Prompt the user to switch to a model with a larger context.
                    recovery = .selectModel
                case .unsupportedModelArchitecture:
                    // The loaded model isn't a chat/instruct LM (vision encoder,
                    // embeddings-only, etc.). The only recovery is picking a
                    // different model.
                    recovery = .selectModel
                default:
                    recovery = .dismissOnly
                }
            } else {
                recovery = .dismissOnly
            }
        } else {
            recovery = .dismissOnly
        }

        let message = if let context {
            "\(context): \(error.localizedDescription)"
        } else {
            error.localizedDescription
        }

        return ChatError(
            kind: kind,
            message: message,
            underlyingError: error,
            recovery: recovery
        )
    }
}
