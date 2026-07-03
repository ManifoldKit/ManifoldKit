import Foundation
import ManifoldOllama

/// Fuzz-local model discovery utilities.
///
/// This used to also carry MLX-directory and GGUF-file discovery for the
/// llama/MLX fuzz factories, mirroring `ManifoldTestSupport.HardwareRequirements`.
/// That half was removed in the v0.64 inert-surface sweep: since the
/// `.llama`/`.mlx` `BackendChoice` cases in `fuzz-chat` fail immediately
/// with a "moved to companion package" message (the MLX/Llama backend
/// families live in manifold-mlx/manifold-llama since v0.48, #1749), no
/// live path in this package ever reached `findMLXModelDirectory`/
/// `findGGUFModel` — they had zero callers.
enum FuzzModelDiscovery {

    // MARK: - Ollama

    static func listOllamaModels(baseURL: URL) -> [String]? {
        guard let models = fetchOllamaModels(baseURL: baseURL) else { return nil }
        return models.map(\.name)
    }

    private static func fetchOllamaModels(baseURL: URL) -> [RemoteModelInfo]? {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var storedValue: [RemoteModelInfo]?

            var value: [RemoteModelInfo]? {
                get {
                    lock.lock()
                    defer { lock.unlock() }
                    return storedValue
                }
                set {
                    lock.lock()
                    defer { lock.unlock() }
                    storedValue = newValue
                }
            }
        }
        let box = Box()

        Task {
            defer { semaphore.signal() }
            do {
                box.value = try await OllamaModelListService().fetchModels(from: baseURL)
            } catch {
                return
            }
        }
        let result = semaphore.wait(timeout: .now() + 5)
        return result == .success ? box.value : nil
    }
}
