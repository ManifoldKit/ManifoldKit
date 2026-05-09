import Foundation

/// Loads bundled scenario JSON from the repo-relative resource directory.
///
/// We intentionally do not use `Bundle.module` here — the scenarios live
/// under `Sources/ManifoldTools/Scenarios/built-in/` and we ship them as
/// plain files the executable discovers at runtime. This keeps the pattern
/// identical for end users who write their own scenarios and pass them via
/// `--scenario-file`.
public enum ScenarioLoader {

    public enum LoadError: Error, CustomStringConvertible {
        case directoryMissing(URL)
        case decodeFailed(URL, Error)

        public var description: String {
            switch self {
            case .directoryMissing(let url):
                return "scenario directory not found: \(url.path)"
            case .decodeFailed(let url, let error):
                return "failed to decode \(url.lastPathComponent): \(error)"
            }
        }
    }

    /// Returns every scenario found in the `built-in` directory, sorted by id
    /// for stable output.
    public static func loadBuiltIn() throws -> [Scenario] {
        let dir = builtInDirectory()
        return try load(from: dir)
    }

    /// Returns every `*.json` in `directory` decoded as a ``Scenario``.
    public static func load(from directory: URL) throws -> [Scenario] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw LoadError.directoryMissing(directory)
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var scenarios: [Scenario] = []
        let decoder = JSONDecoder()
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let scenario = try decoder.decode(Scenario.self, from: data)
                scenarios.append(scenario)
            } catch {
                throw LoadError.decodeFailed(url, error)
            }
        }
        return scenarios
    }

    /// Resolves the bundled scenario directory relative to the current
    /// working directory. SwiftPM invocations (`swift run`, `swift test`) set
    /// CWD to the package root.
    public static func builtInDirectory() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/ManifoldTools/Scenarios/built-in", isDirectory: true)
    }
}
