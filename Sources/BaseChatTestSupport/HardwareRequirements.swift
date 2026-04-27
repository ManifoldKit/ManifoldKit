import Foundation
#if canImport(Metal)
import Metal
#endif

/// Static flags for hardware-gated test skipping.
///
/// Use these with `XCTSkipUnless` / `XCTSkipIf` at the top of tests that
/// require specific hardware or OS capabilities.
public enum HardwareRequirements {

    /// `true` when running on Apple Silicon (arm64). MLX and llama.cpp
    /// backends require this architecture.
    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// `true` when running on a physical device rather than the iOS Simulator.
    /// Metal compute is unavailable in the simulator, so backends that use
    /// GPU acceleration (MLX, llama.cpp) will fail there.
    public static var isPhysicalDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    /// `true` when a real Metal GPU device is accessible in the current process context.
    ///
    /// Apple Silicon may still fail to access Metal when running `swift test` via SSH
    /// or in a headless CI environment without a GPU context. Tests that create
    /// `MLXArray` values must gate on this flag, not just `isAppleSilicon`.
    public static var hasMetalDevice: Bool {
        #if canImport(Metal)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return false
        #endif
    }

    /// `true` when the OS version supports Foundation Models (macOS 26+ / iOS 26+).
    /// This does NOT check whether Apple Intelligence is enabled — use
    /// `FoundationBackend.isAvailable` for that.
    public static var hasFoundationModels: Bool {
        if #available(macOS 26, iOS 26, *) {
            return true
        }
        return false
    }

    // MARK: - Ollama

    /// `true` when a local Ollama server is reachable at `localhost:11434`.
    ///
    /// Performs a synchronous HTTP GET to `/api/tags` with a short timeout.
    /// Use with `XCTSkipUnless` to skip Ollama E2E tests when the server is down.
    public static var hasOllamaServer: Bool {
        fetchOllamaModels() != nil
    }

    /// Returns an Ollama model name, preferring one in the given parameter size range.
    ///
    /// Queries `/api/tags` synchronously. If the `OLLAMA_TEST_MODEL` environment
    /// variable is set AND names a model that is installed locally, that name
    /// wins — CI / local runs can pin to a specific fast model without having to
    /// edit test code. Otherwise prefers models whose `parameter_size` falls in
    /// `preferredSizeRange` (e.g. "7.2B" → 7.2). Falls back to the first
    /// available model if none match the range. Returns `nil` only if the
    /// server is unreachable or has no models.
    public static func findOllamaModel(
        preferredSizeRange: ClosedRange<Double> = 6.5...9.0,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let models = fetchOllamaModels() else { return nil }
        return selectOllamaModel(
            from: models,
            preferredSizeRange: preferredSizeRange,
            environment: environment
        )
    }

    /// Returns the first installed Ollama model whose name contains `substring`,
    /// or `nil` if none match. Returns `nil` if the server is unreachable.
    ///
    /// Unlike `findOllamaModel(preferredSizeRange:environment:)`, this matches by
    /// name only and does not consult `parameter_size`. Use for callers that let
    /// the user nominate a specific model by substring.
    public static func findOllamaModel(
        nameContains substring: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let models = fetchOllamaModels() else { return nil }
        guard let query = normalizedModelSelector(substring) else {
            return selectOllamaModel(from: models, environment: environment)
        }
        for model in models {
            if let name = model["name"] as? String,
               name.localizedCaseInsensitiveContains(query) {
                return name
            }
        }
        return nil
    }

    /// Returns the list of installed Ollama model names, or `nil` if the server
    /// is unreachable.
    public static func listOllamaModels() -> [String]? {
        guard let models = fetchOllamaModels() else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    /// Selects the best model from a pre-fetched Ollama model list.
    /// Extracted from `findOllamaModel` for testability.
    ///
    /// When `environment` carries `OLLAMA_TEST_MODEL` and the named model is in
    /// `models`, that name is returned. Otherwise falls through to the existing
    /// size-based selection logic. Pass an explicit `environment` dictionary
    /// (e.g. `["OLLAMA_TEST_MODEL": "llama3.1:8b"]`) from tests to avoid
    /// depending on the real process environment.
    static func selectOllamaModel(
        from models: [[String: Any]],
        preferredSizeRange: ClosedRange<Double> = 6.5...9.0,
        environment: [String: String] = [:]
    ) -> String? {
        if let override = environment["OLLAMA_TEST_MODEL"], !override.isEmpty {
            for model in models {
                if let name = model["name"] as? String, name == override {
                    return name
                }
            }
        }
        for model in models {
            guard let name = model["name"] as? String,
                  let details = model["details"] as? [String: Any],
                  let paramSize = details["parameter_size"] as? String else { continue }
            let numeric = paramSize.replacingOccurrences(of: "B", with: "")
            if let value = Double(numeric), preferredSizeRange.contains(value) {
                return name
            }
        }
        return models.first?["name"] as? String
    }

    /// Fetches the model list from Ollama's `/api/tags` endpoint synchronously.
    /// Returns `nil` if the server is unreachable or the response is malformed.
    private static func fetchOllamaModels() -> [[String: Any]]? {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var value: [[String: Any]]? }
        let box = Box()

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return }
            box.value = models
        }.resume()
        let result = semaphore.wait(timeout: .now() + 5)
        return result == .success ? box.value : nil
    }

    // MARK: - MLX Models

    /// Scans common model directories for a loadable local MLX model directory.
    ///
    /// Searches:
    /// 1. `~/Documents/Models/` (default `ModelStorageService` location)
    /// 2. App container `Documents/Models/` directories
    ///
    /// When `MLX_TEST_MODEL` is set, the first directory whose path contains that
    /// value wins. Otherwise falls back to `nameContains`, then to the first
    /// discovered candidate in deterministic path order.
    public static func findMLXModelDirectory(
        nameContains substring: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        findMLXModelDirectory(
            in: modelSearchDirectories(fileManager: .default),
            nameContains: substring,
            environment: environment,
            fileManager: .default
        )
    }

    static func findMLXModelDirectory(
        in searchDirs: [URL],
        nameContains substring: String? = nil,
        environment: [String: String] = [:],
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = discoverMLXModelDirectories(in: searchDirs, fileManager: fileManager)
        return selectFilesystemModel(
            from: candidates,
            environmentKey: "MLX_TEST_MODEL",
            nameContains: substring,
            environment: environment
        )
    }

    static func discoverMLXModelDirectories(
        in searchDirs: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        var results: [URL] = []
        for dir in searchDirs {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for candidate in contents {
                if isValidMLXDirectory(candidate, fileManager: fileManager) {
                    results.append(candidate)
                    continue
                }

                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      let nestedContents = try? fileManager.contentsOfDirectory(
                        at: candidate,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                      ) else { continue }

                for nestedCandidate in nestedContents
                where isValidMLXDirectory(nestedCandidate, fileManager: fileManager) {
                    results.append(nestedCandidate)
                }
            }
        }
        return sortedUniqueURLs(results)
    }

    // MARK: - GGUF Models

    /// Scans common model directories for a loadable `.gguf` file.
    ///
    /// Searches the same `Documents/Models/` locations as `findMLXModelDirectory`,
    /// including one nested directory level for manually grouped files such as
    /// `~/Documents/Models/qwen/model.gguf`.
    ///
    /// When `LLAMA_TEST_MODEL` is set, the first GGUF whose path contains that
    /// value wins. Otherwise falls back to `nameContains`, then to the first
    /// discovered candidate in deterministic path order.
    public static func findGGUFModel(
        nameContains substring: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        findGGUFModel(
            in: modelSearchDirectories(fileManager: .default),
            nameContains: substring,
            environment: environment,
            fileManager: .default
        )
    }

    static func findGGUFModel(
        in searchDirs: [URL],
        nameContains substring: String? = nil,
        environment: [String: String] = [:],
        fileManager: FileManager = .default,
        minimumModelSize: Int64 = 50 * 1024 * 1024
    ) -> URL? {
        let candidates = discoverGGUFModels(
            in: searchDirs,
            fileManager: fileManager,
            minimumModelSize: minimumModelSize
        )
        return selectFilesystemModel(
            from: candidates,
            environmentKey: "LLAMA_TEST_MODEL",
            nameContains: substring,
            environment: environment
        )
    }

    static func discoverGGUFModels(
        in searchDirs: [URL],
        fileManager: FileManager = .default,
        minimumModelSize: Int64 = 50 * 1024 * 1024
    ) -> [URL] {
        var results: [URL] = []
        for dir in searchDirs {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for candidate in contents {
                appendGGUFModel(candidate, to: &results, minimumModelSize: minimumModelSize)

                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      let nestedContents = try? fileManager.contentsOfDirectory(
                        at: candidate,
                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                      ) else { continue }

                for nestedCandidate in nestedContents {
                    appendGGUFModel(nestedCandidate, to: &results, minimumModelSize: minimumModelSize)
                }
            }
        }
        return sortedUniqueURLs(results)
    }

    /// Checks whether a directory looks like a loadable local MLX snapshot.
    ///
    /// A directory must contain:
    /// - `config.json` with a non-empty `model_type`
    /// - at least one `.safetensors` weight file
    /// - a Hugging Face tokenizer artifact (`tokenizer.json` or `tokenizer.model`)
    static func isValidMLXDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let configURL = url.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path),
              let configData = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let modelType = json["model_type"] as? String,
              !modelType.isEmpty else {
            return false
        }

        guard let files = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        let fileNames = Set(files.map { $0.lastPathComponent.lowercased() })
        let hasWeights = files.contains { $0.pathExtension.lowercased() == "safetensors" }
        let hasTokenizer = fileNames.contains("tokenizer.json") || fileNames.contains("tokenizer.model")

        return hasWeights && hasTokenizer
    }

    static func isValidGGUFModel(
        _ url: URL,
        minimumModelSize: Int64 = 50 * 1024 * 1024
    ) -> Bool {
        guard url.pathExtension.lowercased() == "gguf" else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true,
              let size = values?.fileSize else {
            return false
        }
        return Int64(size) >= minimumModelSize
    }

    static func selectFilesystemModel(
        from candidates: [URL],
        environmentKey: String,
        nameContains substring: String?,
        environment: [String: String] = [:]
    ) -> URL? {
        let ordered = sortedUniqueURLs(candidates)
        guard !ordered.isEmpty else { return nil }

        if let override = normalizedModelSelector(environment[environmentKey]),
           let matched = matchingFilesystemModel(override, in: ordered) {
            return matched
        }

        if let substring = normalizedModelSelector(substring),
           let matched = matchingFilesystemModel(substring, in: ordered) {
            return matched
        }

        return ordered.first
    }

    static func matchingFilesystemModel(_ query: String, in candidates: [URL]) -> URL? {
        if let exact = candidates.first(where: {
            $0.lastPathComponent.caseInsensitiveCompare(query) == .orderedSame
                || $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(query) == .orderedSame
        }) {
            return exact
        }

        let lowercasedQuery = query.lowercased()
        return candidates.first {
            $0.lastPathComponent.lowercased().contains(lowercasedQuery)
                || $0.deletingPathExtension().lastPathComponent.lowercased().contains(lowercasedQuery)
                || $0.path.lowercased().contains(lowercasedQuery)
        }
    }

    private static func normalizedModelSelector(_ selector: String?) -> String? {
        guard var selector else { return nil }
        selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else { return nil }
        guard selector.lowercased() != "all" else { return nil }
        return selector
    }

    private static func appendGGUFModel(
        _ candidate: URL,
        to results: inout [URL],
        minimumModelSize: Int64
    ) {
        if isValidGGUFModel(candidate, minimumModelSize: minimumModelSize) {
            results.append(candidate)
        }
    }

    private static func sortedUniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        let deduped = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return deduped.sorted {
            $0.standardizedFileURL.path.localizedStandardCompare($1.standardizedFileURL.path) == .orderedAscending
        }
    }

    private static func modelSearchDirectories(fileManager: FileManager) -> [URL] {
        var searchDirs: [URL] = []

        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            searchDirs.append(docs.appendingPathComponent("Models", isDirectory: true))
        }

        if let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let containersDir = library.appendingPathComponent("Containers", isDirectory: true)
            if let containers = try? fileManager.contentsOfDirectory(
                at: containersDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for container in containers {
                    searchDirs.append(
                        container.appendingPathComponent("Data/Documents/Models", isDirectory: true)
                    )
                }
            }
        }

        return searchDirs
    }
}
