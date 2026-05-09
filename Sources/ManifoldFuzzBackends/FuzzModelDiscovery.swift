import Foundation
#if Ollama
import ManifoldBackends
#endif

/// Fuzz-local model discovery utilities.
///
/// These mirror the test harness selection rules without making the importable
/// fuzz backend library depend on `ManifoldTestSupport`.
enum FuzzModelDiscovery {

    // MARK: - Ollama

#if Ollama
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
#endif

    // MARK: - MLX Models

    static func findMLXModelDirectory(
        nameContains substring: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = directFilesystemModelOverride(
            environment["MLX_TEST_MODEL"],
            isValid: { isValidMLXDirectory($0, fileManager: .default) }
        ) {
            return override
        }
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

    private static func discoverMLXModelDirectories(
        in searchDirs: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        var results: [URL] = []
        for dir in searchDirs {
            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                continue
            }

            for candidate in contents {
                if isValidMLXDirectory(candidate, fileManager: fileManager) {
                    results.append(candidate)
                    continue
                }

                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let nestedContents: [URL]
                do {
                    nestedContents = try fileManager.contentsOfDirectory(
                        at: candidate,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    continue
                }

                for nestedCandidate in nestedContents
                where isValidMLXDirectory(nestedCandidate, fileManager: fileManager) {
                    results.append(nestedCandidate)
                }
            }
        }
        return sortedUniqueURLs(results)
    }

    // MARK: - GGUF Models

    static func findGGUFModel(
        nameContains substring: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maximumModelSize: Int64? = nil
    ) -> URL? {
        if let override = directFilesystemModelOverride(
            environment["LLAMA_TEST_MODEL"],
            isValid: { isValidGGUFModel($0, maximumModelSize: maximumModelSize) }
        ) {
            return override
        }
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

    private static func discoverGGUFModelCandidates(
        in searchDirs: [URL],
        fileManager: FileManager = .default,
        minimumModelSize: Int64,
        maximumModelSize: Int64?
    ) -> [GGUFModelCandidate] {
        var results: [GGUFModelCandidate] = []
        for dir in searchDirs {
            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                continue
            }

            for candidate in contents {
                appendGGUFModel(
                    candidate,
                    to: &results,
                    minimumModelSize: minimumModelSize,
                    maximumModelSize: maximumModelSize
                )

                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let nestedContents: [URL]
                do {
                    nestedContents = try fileManager.contentsOfDirectory(
                        at: candidate,
                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    continue
                }

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

    private static func isValidMLXDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let configURL = url.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path) else { return false }
        do {
            let configData = try Data(contentsOf: configURL)
            guard let json = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
                  let modelType = json["model_type"] as? String,
                  !modelType.isEmpty else {
                return false
            }
        } catch {
            return false
        }

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return false
        }

        let fileNames = Set(files.map { $0.lastPathComponent.lowercased() })
        let hasWeights = files.contains { $0.pathExtension.lowercased() == "safetensors" }
        let hasTokenizer = fileNames.contains("tokenizer.json") || fileNames.contains("tokenizer.model")

        return hasWeights && hasTokenizer
    }

    private static func isValidGGUFModel(
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

    private static func selectFilesystemModel(
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

    private static func matchingFilesystemModel(_ query: String, in candidates: [URL]) -> URL? {
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
        return environment["BASECHAT_DISCOVER_LOCAL_MODELS"] == "1"
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
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            return nil
        }
        guard values.isRegularFile == true,
              let size = values.fileSize else {
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
            let containers: [URL]
            do {
                containers = try fileManager.contentsOfDirectory(
                    at: containersDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                return searchDirs
            }
            for container in containers {
                searchDirs.append(
                    container.appendingPathComponent("Data/Documents/Models", isDirectory: true)
                )
            }
        }

        return searchDirs
    }
}
