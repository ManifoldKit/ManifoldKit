/// Typed identifiers for the local-engine and SaaS backends BCK ships.
///
/// Use these instead of raw string literals when branching on the active
/// backend:
///
/// ```swift
/// if vm.activeBackendName == BackendName.foundation.rawValue {
///     // Foundation-specific behaviour
/// }
/// ```
///
/// `activeBackendName` is still typed as `String?` because the lifecycle
/// coordinator also surfaces cloud providers (`lmStudio`, `custom`,
/// `openAIResponses`) and free-form labels from test backends, neither of
/// which fit a closed enum. For the six cases below — the engines and
/// SaaS providers BCK has first-class support for — `BackendName.<case>.rawValue`
/// is the canonical comparison shape.
///
/// ## Migration from 0.18.x
///
/// In 0.18 and earlier, `BackendName` was a no-instances container of
/// `static let` strings whose values were the *display* names emitted by
/// `InferenceService.activeBackendName` (`"Apple"`, `"Ollama"`, …). 0.19
/// converts it into a real `enum: String` whose raw values are the
/// canonical lowercase identifiers (`"foundation"`, `"ollama"`, …).
///
/// Comparison sites that always wrote `vm.activeBackendName == BackendName.foundation`
/// continue to compile and behave correctly — the right-hand side moves with
/// the lifecycle coordinator's emitted strings.
///
/// Code that hardcoded the legacy strings (`if name == "Apple"`) needs to
/// switch to the typed accessor or use ``parse(_:)`` to accept both shapes.
public enum BackendName: String, Sendable, CaseIterable, Codable, Hashable {
    /// The Apple Foundation Models backend (canonical raw value: `"foundation"`).
    /// Legacy 0.18 raw value: `"Apple"`.
    case foundation = "foundation"
    /// The Ollama backend (canonical raw value: `"ollama"`).
    /// Legacy 0.18 raw value: `"Ollama"`.
    case ollama = "ollama"
    /// The Claude (Anthropic) backend (canonical raw value: `"claude"`).
    /// Legacy 0.18 raw value: `"Claude"`.
    case claude = "claude"
    /// The OpenAI Chat-Completions / OpenAI-compatible backend (canonical raw value: `"openAI"`).
    /// Legacy 0.18 raw value: `"OpenAI"`.
    case openAI = "openAI"
    /// The MLX backend (canonical raw value: `"mlx"`).
    /// Legacy 0.18 raw value: `"MLX"`.
    case mlx = "mlx"
    /// The llama.cpp (GGUF) backend (canonical raw value: `"llama"`).
    /// Legacy 0.18 raw value: `"llama.cpp"`.
    case llama = "llama"
}

extension BackendName {
    /// Accepts the 0.19+ canonical raw values *and* the 0.18.x legacy
    /// display strings (`"Apple"`, `"Ollama"`, `"llama.cpp"`, …).
    ///
    /// Use this at every trust boundary that reads a backend-name string
    /// from disk, wire formats, or persisted user defaults that may
    /// pre-date the rename. Comparing two freshly produced 0.19 strings
    /// can use `BackendName(rawValue:)`; ``parse(_:)`` is the migration
    /// affordance that absorbs the legacy shape so we don't strand any
    /// already-installed apps on the old form.
    ///
    /// Returns `nil` for any string that doesn't match either form so the
    /// caller can decide whether to log, reject, or fall back.
    public static func parse(_ string: String) -> BackendName? {
        if let canonical = BackendName(rawValue: string) { return canonical }
        switch string {
        case "Apple": return .foundation
        case "Ollama": return .ollama
        case "Claude": return .claude
        case "OpenAI": return .openAI
        case "MLX": return .mlx
        case "llama.cpp": return .llama
        default: return nil
        }
    }
}
