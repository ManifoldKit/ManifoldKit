import Foundation

/// Loads the bundled scenario corpus from the package resource bundle.
///
/// The `built-in` directory is declared as a `.copy` resource on the
/// `ManifoldTools` target (see `Package.swift`), so the canonical corpus ships
/// inside `Bundle.module` and resolves regardless of the process working
/// directory — `swift run`, `swift test`, an installed `manifold-tools`
/// binary, or a companion package that depends on this target all see the
/// single canonical corpus. The previous implementation resolved a
/// `Sources/ManifoldTools/Scenarios/built-in` path relative to the current
/// working directory, which only worked when the CWD happened to be the
/// package root and forced companions to vendor drift-prone copies.
///
/// End users who write their own scenarios still pass them explicitly via
/// ``load(from:)`` / `--scenario-file`.
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

    /// Returns every scenario in the bundled `built-in` corpus, sorted by id
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

    /// Resolves the bundled scenario directory from the package resource
    /// bundle (`Bundle.module`). Independent of the working directory, so the
    /// corpus loads identically under `swift run`, `swift test`, an installed
    /// CLI, or a downstream consumer of the `ManifoldTools` library.
    ///
    /// Falls back to the legacy CWD-relative path only if the resource bundle
    /// somehow lacks the `built-in` directory (a packaging regression). That
    /// fallback URL is non-existent in any normal install, so ``load(from:)``
    /// surfaces a clear ``LoadError/directoryMissing(_:)`` rather than silently
    /// returning an empty corpus.
    public static func builtInDirectory() -> URL {
        if let bundled = Bundle.module.url(forResource: "built-in", withExtension: nil) {
            return bundled
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/ManifoldTools/Scenarios/built-in", isDirectory: true)
    }
}
