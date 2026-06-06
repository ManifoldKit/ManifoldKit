import Foundation

/// How the backend loads model weights into memory.
public enum MemoryStrategy: String, Sendable, Equatable, Codable {
    /// Model must be fully resident in RAM (e.g., MLX on unified memory).
    case resident
    /// Model is memory-mapped; only active pages + KV cache need RAM (e.g., llama.cpp).
    case mappable
    /// No local model memory needed (cloud APIs, OS-managed models).
    case external
}
