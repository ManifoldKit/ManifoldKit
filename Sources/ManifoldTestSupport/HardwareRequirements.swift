import Foundation
#if canImport(Metal)
import Metal
#endif

/// Static flags for hardware-gated test skipping.
///
/// Use these with `XCTSkipUnless` / `XCTSkipIf` at the top of tests that
/// require specific hardware or OS capabilities.
enum HardwareRequirements {

    /// `true` when running on Apple Silicon (arm64). MLX and llama.cpp
    /// backends require this architecture.
    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// `true` when running on a physical device rather than the iOS Simulator.
    /// Metal compute is unavailable in the simulator, so backends that use
    /// GPU acceleration (MLX, llama.cpp) will fail there.
    static var isPhysicalDevice: Bool {
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
    static var hasMetalDevice: Bool {
        #if canImport(Metal)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return false
        #endif
    }

    /// `true` when the OS version supports Foundation Models (macOS 26+ / iOS 26+).
    /// This does NOT check whether Apple Intelligence is enabled — use
    /// `FoundationBackend.isAvailable` for that.
    static var hasFoundationModels: Bool {
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
    static var hasOllamaServer: Bool {
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
    static func findOllamaModel(
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
    static func findOllamaModel(
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
    static func listOllamaModels() -> [String]? {
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
    /// To avoid unbounded walks through user model folders during routine test
    /// runs, common-directory discovery is opt-in. Set `MLX_TEST_MODEL` or pass
    /// `nameContains` to select a specific fixture, or set
    /// `MANIFOLD_DISCOVER_LOCAL_MODELS=1` to allow fallback discovery.
    ///
    /// When `MLX_TEST_MODEL` is set to an absolute or tilde-relative path,
    /// that path is validated directly. If the path does not resolve to a valid
    /// MLX model directory the function returns `nil` — it does NOT fall back
    /// to local discovery, so that a misconfigured path surfaces as a skip
    /// rather than silently running against a different model.
    ///
    /// When `MLX_TEST_MODEL` is set to a bare name or substring (no `/`),
    /// discovery runs and the first candidate whose path contains the value wins.
    /// Falls back to `nameContains`, then to the first discovered candidate in
    /// deterministic path order.
    static func findMLXModelDirectory(
        nameContains substring: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let rawSelector = environment["MLX_TEST_MODEL"]
        if let override = directFilesystemModelOverride(
            rawSelector,
            isValid: { isValidMLXDirectory($0, fileManager: .default) }
        ) {
            return override
        }
        // When the selector looks like a direct path but failed validation,
        // return nil immediately so callers skip rather than accidentally running
        // against a different discovered model.
        if isDirectPathSelector(rawSelector) { return nil }
        guard shouldDiscoverLocalModels(
            environment: environment,
            selectorKey: "MLX_TEST_MODEL",
            nameContains: substring
        ) else {
            return nil
        }
        return findMLXModelDirectory(
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
    /// To avoid unbounded walks through user model folders during routine test
    /// runs, common-directory discovery is opt-in. Set `LLAMA_TEST_MODEL` or pass
    /// `nameContains` to select a specific fixture, or set
    /// `MANIFOLD_DISCOVER_LOCAL_MODELS=1` to allow fallback discovery.
    ///
    /// When `LLAMA_TEST_MODEL` is set to an absolute or tilde-relative path,
    /// that path is validated directly. If the path does not resolve to a valid
    /// GGUF file the function returns `nil` — it does NOT fall back to local
    /// discovery, so that a misconfigured path surfaces as a skip rather than
    /// silently running against a different model.
    ///
    /// When `LLAMA_TEST_MODEL` is set to a bare name or substring (no `/`),
    /// discovery runs and the first candidate whose path contains the value wins.
    /// Falls back to `nameContains`, then to the smallest discovered candidate
    /// that satisfies the size bounds.
    static func findGGUFModel(
        nameContains substring: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maximumModelSize: Int64? = nil
    ) -> URL? {
        let rawSelector = environment["LLAMA_TEST_MODEL"]
        if let override = directFilesystemModelOverride(
            rawSelector,
            isValid: { isValidGGUFModel($0, maximumModelSize: maximumModelSize) }
        ) {
            return override
        }
        // When the selector looks like a direct path but failed validation,
        // return nil immediately so callers skip rather than accidentally running
        // against a different discovered model.
        if isDirectPathSelector(rawSelector) { return nil }
        guard shouldDiscoverLocalModels(
            environment: environment,
            selectorKey: "LLAMA_TEST_MODEL",
            nameContains: substring
        ) else {
            return nil
        }
        return findGGUFModel(
            in: modelSearchDirectories(fileManager: .default),
            nameContains: substring,
            environment: environment,
            fileManager: .default,
            maximumModelSize: maximumModelSize
        )
    }

    static func findGGUFModel(
        in searchDirs: [URL],
        nameContains substring: String? = nil,
        environment: [String: String] = [:],
        fileManager: FileManager = .default,
        minimumModelSize: Int64 = 50 * 1024 * 1024,
        maximumModelSize: Int64? = nil
    ) -> URL? {
        let candidates = discoverGGUFModelCandidates(
            in: searchDirs,
            fileManager: fileManager,
            minimumModelSize: minimumModelSize,
            maximumModelSize: maximumModelSize
        )
        return selectGGUFModel(
            from: candidates,
            environmentKey: "LLAMA_TEST_MODEL",
            nameContains: substring,
            environment: environment
        )
    }

    static func discoverGGUFModels(
        in searchDirs: [URL],
        fileManager: FileManager = .default,
        minimumModelSize: Int64 = 50 * 1024 * 1024,
        maximumModelSize: Int64? = nil
    ) -> [URL] {
        discoverGGUFModelCandidates(
            in: searchDirs,
            fileManager: fileManager,
            minimumModelSize: minimumModelSize,
            maximumModelSize: maximumModelSize
        ).map(\.url)
    }

    private static func discoverGGUFModelCandidates(
        in searchDirs: [URL],
        fileManager: FileManager = .default,
        minimumModelSize: Int64,
        maximumModelSize: Int64?
    ) -> [GGUFModelCandidate] {
        var results: [GGUFModelCandidate] = []
        for dir in searchDirs {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for candidate in contents {
                appendGGUFModel(
                    candidate,
                    to: &results,
                    minimumModelSize: minimumModelSize,
                    maximumModelSize: maximumModelSize
                )

                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      let nestedContents = try? fileManager.contentsOfDirectory(
                        at: candidate,
                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                      ) else { continue }

                for nestedCandidate in nestedContents {
                    appendGGUFModel(
                        nestedCandidate,
                        to: &results,
                        minimumModelSize: minimumModelSize,
                        maximumModelSize: maximumModelSize
                    )
                }
            }
        }
        return sortedUniqueGGUFCandidates(results)
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
        minimumModelSize: Int64 = 50 * 1024 * 1024,
        maximumModelSize: Int64? = nil
    ) -> Bool {
        ggufModelCandidate(
            url,
            minimumModelSize: minimumModelSize,
            maximumModelSize: maximumModelSize
        ) != nil
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

    private static func shouldDiscoverLocalModels(
        environment: [String: String],
        selectorKey: String,
        nameContains substring: String?
    ) -> Bool {
        if normalizedModelSelector(environment[selectorKey]) != nil { return true }
        if normalizedModelSelector(substring) != nil { return true }
        return environment["MANIFOLD_DISCOVER_LOCAL_MODELS"] == "1"
    }

    /// Returns `true` when `selector` looks like a direct filesystem path
    /// (i.e. contains a `/` after normalisation), meaning the caller intended
    /// to point at a specific file/directory rather than supply a name fragment.
    ///
    /// Used to prevent a misconfigured absolute path from silently falling
    /// through to local-model discovery: if the path looks intentional but
    /// fails validation, callers should return `nil` so tests skip with a
    /// clear message rather than running against an unexpected model.
    private static func isDirectPathSelector(_ selector: String?) -> Bool {
        guard let selector = normalizedModelSelector(selector) else { return false }
        let expanded = (selector as NSString).expandingTildeInPath
        return expanded.contains("/")
    }

    private static func directFilesystemModelOverride(
        _ selector: String?,
        isValid: (URL) -> Bool
    ) -> URL? {
        guard let selector = normalizedModelSelector(selector) else { return nil }
        let expanded = (selector as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard url.isFileURL, expanded.contains("/") else { return nil }
        return isValid(url) ? url : nil
    }

    private static func selectGGUFModel(
        from candidates: [GGUFModelCandidate],
        environmentKey: String,
        nameContains substring: String?,
        environment: [String: String] = [:]
    ) -> URL? {
        let ordered = sortedUniqueGGUFCandidates(candidates).map(\.url)
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

    private static func appendGGUFModel(
        _ candidate: URL,
        to results: inout [GGUFModelCandidate],
        minimumModelSize: Int64,
        maximumModelSize: Int64?
    ) {
        if let candidate = ggufModelCandidate(
            candidate,
            minimumModelSize: minimumModelSize,
            maximumModelSize: maximumModelSize
        ) {
            results.append(candidate)
        }
    }

    private static func ggufModelCandidate(
        _ url: URL,
        minimumModelSize: Int64,
        maximumModelSize: Int64?
    ) -> GGUFModelCandidate? {
        guard url.pathExtension.lowercased() == "gguf" else { return nil }
        // Resolve symlinks so that a symlink to a blob (e.g. ~/.ollama/models/blobs/sha256-*)
        // passes the isRegularFile check — symlinks are not themselves regular files.
        let fileURL = url.resolvingSymlinksInPath()
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true,
              let size = values?.fileSize else {
            return nil
        }
        let modelSize = Int64(size)
        guard modelSize >= minimumModelSize else { return nil }
        if let maximumModelSize, modelSize > maximumModelSize { return nil }
        return GGUFModelCandidate(url: url, size: modelSize)
    }

    private static func sortedUniqueGGUFCandidates(
        _ candidates: [GGUFModelCandidate]
    ) -> [GGUFModelCandidate] {
        var seen: Set<String> = []
        let deduped = candidates.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
        return deduped.sorted { lhs, rhs in
            if lhs.size != rhs.size { return lhs.size < rhs.size }
            return lhs.url.standardizedFileURL.path.localizedStandardCompare(
                rhs.url.standardizedFileURL.path
            ) == .orderedAscending
        }
    }

    private struct GGUFModelCandidate {
        let url: URL
        let size: Int64
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
