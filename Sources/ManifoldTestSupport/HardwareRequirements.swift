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

    /// Returns the name of an installed, tool-calling-capable Ollama model, or
    /// `nil` if the server is unreachable or no installed model advertises the
    /// `"tools"` capability.
    ///
    /// Capability is probed via Ollama's `/api/show` endpoint, whose
    /// `capabilities` array carries `"tools"` for models with native tool
    /// support — so this discovers newer tool-callers (e.g. `qwen3.5`,
    /// `gemma4`) without hardcoding model names.
    ///
    /// Selection order:
    /// 1. If `OLLAMA_TEST_MODEL` is set, is installed, and is tool-capable, use it.
    /// 2. Otherwise iterate installed models and return the first whose
    ///    `/api/show` capabilities contain `"tools"`.
    public static func findOllamaToolCapableModel(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let names = listOllamaModels() else { return nil }
        return selectOllamaToolCapableModel(
            from: names,
            environment: environment,
            isToolCapable: { ollamaModelIsToolCapable($0) }
        )
    }

    /// Picks a tool-capable model name from a pre-fetched list, given a
    /// capability probe. Extracted from `findOllamaToolCapableModel` so it can
    /// be unit-tested without a live server: inject a stub `isToolCapable`.
    ///
    /// When `OLLAMA_TEST_MODEL` names an installed *and* tool-capable model it
    /// wins; otherwise the first installed model that probes tool-capable is
    /// returned.
    public static func selectOllamaToolCapableModel(
        from names: [String],
        environment: [String: String] = [:],
        isToolCapable: (String) -> Bool
    ) -> String? {
        if let override = environment["OLLAMA_TEST_MODEL"], !override.isEmpty,
           names.contains(override), isToolCapable(override) {
            return override
        }
        return names.first(where: isToolCapable)
    }

    /// Probes Ollama's `/api/show` for `name` and reports whether its
    /// `capabilities` array contains `"tools"`. Returns `false` on any
    /// transport/decoding failure (treated as "not tool-capable").
    public static func ollamaModelIsToolCapable(_ name: String) -> Bool {
        ollamaModelCapabilities(name)?.contains("tools") ?? false
    }

    /// Fetches the `capabilities` array for a model from `/api/show`
    /// synchronously. Returns `nil` if the server is unreachable or the
    /// response is malformed.
    private static func ollamaModelCapabilities(_ name: String) -> [String]? {
        guard let url = URL(string: "http://localhost:11434/api/show") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3
        guard let body = try? JSONSerialization.data(
            withJSONObject: ["model": name]
        ) else { return nil }
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var value: [String]? }
        let box = Box()

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let capabilities = json["capabilities"] as? [String] else { return }
            box.value = capabilities
        }.resume()
        let result = semaphore.wait(timeout: .now() + 5)
        return result == .success ? box.value : nil
    }

    /// Selects the best model from a pre-fetched Ollama model list.
    /// Extracted from `findOllamaModel` for testability.
    ///
    /// When `environment` carries `OLLAMA_TEST_MODEL` and the named model is in
    /// `models`, that name is returned. Otherwise falls through to the existing
    /// size-based selection logic. Pass an explicit `environment` dictionary
    /// (e.g. `["OLLAMA_TEST_MODEL": "llama3.1:8b"]`) from tests to avoid
    /// depending on the real process environment.
    public static func selectOllamaModel(
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
    /// If that name fragment matches nothing the function returns `nil` (the
    /// caller skips) rather than falling back to an unrelated model. Falls back
    /// to `nameContains` only when the env key is absent; if neither name
    /// selector is supplied and `MANIFOLD_DISCOVER_LOCAL_MODELS=1`, the first
    /// discovered candidate in deterministic path order wins.
    public static func findMLXModelDirectory(
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

    public static func findMLXModelDirectory(
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

    /// Maximum directory depth below each search root for MLX snapshot discovery.
    ///
    /// Depth 0 is the search root itself. Depth 4 covers common grouped
    /// layouts such as `Models/mlx/<ModelName>/` (depth 2) and
    /// `Models/mlx/<org>/<ModelName>/` (depth 3) without walking unbounded
    /// user trees. Mirrors ``ggufDiscoveryMaxDepth``.
    public static let mlxDiscoveryMaxDepth = 4

    public static func discoverMLXModelDirectories(
        in searchDirs: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        var results: [URL] = []
        for dir in searchDirs {
            walkMLXModelDirectories(
                at: dir,
                depth: 0,
                maxDepth: mlxDiscoveryMaxDepth,
                fileManager: fileManager,
                results: &results
            )
        }
        return sortedUniqueURLs(results)
    }

    private static func walkMLXModelDirectories(
        at directory: URL,
        depth: Int,
        maxDepth: Int,
        fileManager: FileManager,
        results: inout [URL]
    ) {
        guard depth <= maxDepth else { return }
        if depth > 0, isValidMLXDirectory(directory, fileManager: fileManager) {
            results.append(directory)
            // A valid MLX snapshot is a leaf for discovery — do not descend into
            // its weight shards / tokenizer artifacts looking for nested models.
            return
        }
        guard depth < maxDepth else { return }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for candidate in contents {
            guard shouldDescendIntoDiscoveryDirectory(candidate, fileManager: fileManager) else {
                continue
            }
            walkMLXModelDirectories(
                at: candidate,
                depth: depth + 1,
                maxDepth: maxDepth,
                fileManager: fileManager,
                results: &results
            )
        }
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
    /// If that name fragment matches nothing the function returns `nil` (the
    /// caller skips) rather than falling back to an unrelated model. Falls back
    /// to `nameContains` only when the env key is absent; if neither name
    /// selector is supplied and `MANIFOLD_DISCOVER_LOCAL_MODELS=1`, the smallest
    /// discovered candidate that satisfies the size bounds wins.
    public static func findGGUFModel(
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

    public static func findGGUFModel(
        in searchDirs: [URL],
        nameContains substring: String? = nil,
        environment: [String: String] = [:],
        fileManager: FileManager = .default,
        minimumModelSize: Int64 = 50 * 1024 * 1024,
        maximumModelSize: Int64? = nil
    ) -> URL? {
        let (candidates, diagnostics) = discoverGGUFModelCandidates(
            in: searchDirs,
            fileManager: fileManager,
            minimumModelSize: minimumModelSize,
            maximumModelSize: maximumModelSize
        )
        let selected = selectGGUFModel(
            from: candidates,
            environmentKey: "LLAMA_TEST_MODEL",
            nameContains: substring,
            environment: environment
        )
        // Only when discovery found .gguf files and *none* were loadable —
        // not when loadable models exist but a name selector missed (that
        // path still returns nil without a false "Discovered N" log line).
        // Quiet when the tree is simply empty (common XCTSkip). Typed skip
        // messages: ``discoverGGUFModelsWithDiagnostics``.
        if selected == nil,
           diagnostics.acceptedCount == 0,
           diagnostics.rejectedGGUFFileCount > 0 {
            fputs("HardwareRequirements.findGGUFModel: \(diagnostics.skipMessage)\n", stderr)
        }
        return selected
    }

    /// Maximum directory depth below each search root for GGUF file discovery.
    ///
    /// Depth 0 is the search root itself (e.g. `~/Documents/Models`). Depth 4
    /// reaches the common family-grouped layout
    /// `Models/<family>/<name>/<file>.gguf` (depth 3) plus one extra nesting
    /// level, without unbounded recursion over user model trees. Hidden
    /// directories and known non-model trees (`.cache`, Hugging Face download
    /// sidecars, etc.) are skipped — see ``shouldDescendIntoDiscoveryDirectory``.
    public static let ggufDiscoveryMaxDepth = 4

    /// Outcome of a GGUF discovery walk: accepted models plus counts that let
    /// callers distinguish "nothing on disk" from "saw `.gguf` files but none
    /// passed size/validation bounds" (#2384).
    public struct GGUFDiscoveryDiagnostics: Sendable, Equatable {
        public let acceptedCount: Int
        /// `.gguf` paths visited that failed size bounds or regular-file checks.
        public let rejectedGGUFFileCount: Int
        public let scannedDirectoryCount: Int
        public let maxDepth: Int

        /// Message suitable for `XCTSkip` / log lines when discovery yields no model.
        public var skipMessage: String {
            if acceptedCount > 0 {
                return "Discovered \(acceptedCount) loadable GGUF model(s)."
            }
            if rejectedGGUFFileCount > 0 {
                return "Found \(rejectedGGUFFileCount) .gguf file(s) but none were loadable "
                    + "(size bounds / validation failed; scanned \(scannedDirectoryCount) "
                    + "directories to depth \(maxDepth))."
            }
            return "No GGUF models found under search roots "
                + "(scanned \(scannedDirectoryCount) directories to depth \(maxDepth))."
        }
    }

    public static func discoverGGUFModels(
        in searchDirs: [URL],
        fileManager: FileManager = .default,
        minimumModelSize: Int64 = 50 * 1024 * 1024,
        maximumModelSize: Int64? = nil
    ) -> [URL] {
        discoverGGUFModelsWithDiagnostics(
            in: searchDirs,
            fileManager: fileManager,
            minimumModelSize: minimumModelSize,
            maximumModelSize: maximumModelSize
        ).models
    }

    /// Same walk as ``discoverGGUFModels(in:fileManager:minimumModelSize:maximumModelSize:)``
    /// plus diagnostics for honest skip messaging.
    public static func discoverGGUFModelsWithDiagnostics(
        in searchDirs: [URL],
        fileManager: FileManager = .default,
        minimumModelSize: Int64 = 50 * 1024 * 1024,
        maximumModelSize: Int64? = nil
    ) -> (models: [URL], diagnostics: GGUFDiscoveryDiagnostics) {
        let (candidates, diagnostics) = discoverGGUFModelCandidates(
            in: searchDirs,
            fileManager: fileManager,
            minimumModelSize: minimumModelSize,
            maximumModelSize: maximumModelSize
        )
        return (candidates.map(\.url), diagnostics)
    }

    private static func discoverGGUFModelCandidates(
        in searchDirs: [URL],
        fileManager: FileManager = .default,
        minimumModelSize: Int64,
        maximumModelSize: Int64?
    ) -> ([GGUFModelCandidate], GGUFDiscoveryDiagnostics) {
        var results: [GGUFModelCandidate] = []
        var rejectedGGUFFileCount = 0
        var scannedDirectoryCount = 0
        for dir in searchDirs {
            walkGGUFModelCandidates(
                at: dir,
                depth: 0,
                maxDepth: ggufDiscoveryMaxDepth,
                fileManager: fileManager,
                minimumModelSize: minimumModelSize,
                maximumModelSize: maximumModelSize,
                results: &results,
                rejectedGGUFFileCount: &rejectedGGUFFileCount,
                scannedDirectoryCount: &scannedDirectoryCount
            )
        }
        let ordered = sortedUniqueGGUFCandidates(results)
        let diagnostics = GGUFDiscoveryDiagnostics(
            acceptedCount: ordered.count,
            rejectedGGUFFileCount: rejectedGGUFFileCount,
            scannedDirectoryCount: scannedDirectoryCount,
            maxDepth: ggufDiscoveryMaxDepth
        )
        return (ordered, diagnostics)
    }

    private static func walkGGUFModelCandidates(
        at directory: URL,
        depth: Int,
        maxDepth: Int,
        fileManager: FileManager,
        minimumModelSize: Int64,
        maximumModelSize: Int64?,
        results: inout [GGUFModelCandidate],
        rejectedGGUFFileCount: inout Int,
        scannedDirectoryCount: inout Int
    ) {
        guard depth <= maxDepth else { return }
        scannedDirectoryCount += 1
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for candidate in contents {
            if candidate.pathExtension.lowercased() == "gguf" {
                if let model = ggufModelCandidate(
                    candidate,
                    minimumModelSize: minimumModelSize,
                    maximumModelSize: maximumModelSize
                ) {
                    results.append(model)
                } else {
                    rejectedGGUFFileCount += 1
                }
                continue
            }

            guard depth < maxDepth,
                  shouldDescendIntoDiscoveryDirectory(candidate, fileManager: fileManager) else {
                continue
            }
            walkGGUFModelCandidates(
                at: candidate,
                depth: depth + 1,
                maxDepth: maxDepth,
                fileManager: fileManager,
                minimumModelSize: minimumModelSize,
                maximumModelSize: maximumModelSize,
                results: &results,
                rejectedGGUFFileCount: &rejectedGGUFFileCount,
                scannedDirectoryCount: &scannedDirectoryCount
            )
        }
    }

    /// Directory names that are never model trees — never descend.
    ///
    /// Hidden directories (including `.cache`) are already excluded by
    /// `.skipsHiddenFiles`. Keep this list tight: bare names like
    /// `huggingface` or `downloads` are legitimate family roots for some
    /// layouts (`Models/huggingface/<org>/<model>/`), so excluding them
    /// would reintroduce silent skips (#2384 review).
    private static let discoveryExcludedDirectoryNames: Set<String> = [
        // Ollama / blob-store content — not chat GGUF layouts.
        "blobs",
    ]

    private static func shouldDescendIntoDiscoveryDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return false }
        if discoveryExcludedDirectoryNames.contains(name.lowercased()) { return false }
        // Hugging Face download sidecars: `…/huggingface/download/…` holds
        // partial blobs / lock files, not loadable model roots.
        if name.lowercased() == "download" || name.lowercased() == "downloads" {
            let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
            if parent == "huggingface" || parent == ".cache" || parent == "cache" {
                return false
            }
        }
        return true
    }

    /// Checks whether a directory looks like a loadable local MLX snapshot.
    ///
    /// A directory must contain:
    /// - `config.json` with a non-empty `model_type`
    /// - at least one `.safetensors` weight file
    /// - a Hugging Face tokenizer artifact (`tokenizer.json` or `tokenizer.model`)
    public static func isValidMLXDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
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

    public static func isValidGGUFModel(
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

    public static func selectFilesystemModel(
        from candidates: [URL],
        environmentKey: String,
        nameContains substring: String?,
        environment: [String: String] = [:]
    ) -> URL? {
        let ordered = sortedUniqueURLs(candidates)
        guard !ordered.isEmpty else { return nil }

        // An explicit name selector — supplied via the env key or the
        // `nameContains` argument — is a request for a *specific* model. If it
        // matches nothing, return nil so the caller skips rather than silently
        // running against an unrelated model. Only when no name selector was
        // provided at all do we fall back to the first candidate (the legit
        // "any model" discovery path). Mirrors `findOllamaModel(nameContains:)`.
        let envSelector = normalizedModelSelector(environment[environmentKey])
        let argSelector = normalizedModelSelector(substring)

        if let envSelector {
            return matchingFilesystemModel(envSelector, in: ordered)
        }

        if let argSelector {
            return matchingFilesystemModel(argSelector, in: ordered)
        }

        return ordered.first
    }

    public static func matchingFilesystemModel(_ query: String, in candidates: [URL]) -> URL? {
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

        // An explicit name selector — supplied via the env key or the
        // `nameContains` argument — is a request for a *specific* model. If it
        // matches nothing, return nil so the caller skips rather than silently
        // running against an unrelated (smaller) model. Only when no name
        // selector was provided at all do we fall back to the smallest
        // candidate (the legit "any model" discovery path). Mirrors
        // `findOllamaModel(nameContains:)`.
        let envSelector = normalizedModelSelector(environment[environmentKey])
        let argSelector = normalizedModelSelector(substring)

        if let envSelector {
            return matchingFilesystemModel(envSelector, in: ordered)
        }

        if let argSelector {
            return matchingFilesystemModel(argSelector, in: ordered)
        }

        return ordered.first
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
