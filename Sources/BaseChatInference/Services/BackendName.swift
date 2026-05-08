import Foundation

/// Typed constants for the backend-name strings returned by
/// ``InferenceService/activeBackendName``.
///
/// Use these instead of raw string literals when branching on the active backend:
///
/// ```swift
/// if vm.activeBackendName == BackendName.foundation {
///     // Foundation-specific behaviour
/// }
/// ```
public enum BackendName {
    /// The Apple Foundation Models backend (`"Apple"`).
    public static let foundation = "Apple"
    /// The Ollama backend (`"Ollama"`).
    public static let ollama = "Ollama"
    /// The Claude (Anthropic) backend (`"Claude"`).
    public static let claude = "Claude"
    /// The OpenAI-compatible backend (`"OpenAI"`).
    public static let openAI = "OpenAI"
    /// The MLX backend (`"MLX"`).
    public static let mlx = "MLX"
    /// The llama.cpp backend (`"Llama"`).
    public static let llama = "Llama"
}
