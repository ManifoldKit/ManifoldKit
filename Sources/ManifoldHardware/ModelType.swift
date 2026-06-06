import Foundation

/// The inference backend a model requires, determined by its file format.
public enum ModelType: Hashable, Sendable {
    /// A single `.gguf` file — uses the llama.cpp backend.
    case gguf
    /// A directory containing `config.json` + `.safetensors` weights — uses MLX.
    case mlx
    /// Apple on-device model, no file needed.
    case foundation
}
