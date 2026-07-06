import Foundation

/// Loads ``GoldenTaskFixture`` values from JSON.
///
/// ManifoldAppEval ships no built-in fixture corpus of its own (unlike
/// `ManifoldTools.ScenarioLoader`, which bundles a canonical scenario set via
/// `Bundle.module`) — every fixture here is app-authored. The house pattern
/// still applies to *app* consumers: a golden fixture directory should be
/// resolved via that app's own `Bundle.module` (or an explicit path an app
/// controls), never a CWD-relative path — CWD-relative resolution only
/// happens to work when the process runs from the package root (every
/// in-repo `swift test`/`swift run`), and silently breaks for an installed
/// binary or a differently-laid-out CI runner. `loadAll(from:)` therefore
/// takes a caller-resolved `URL` rather than guessing a directory itself.
public enum GoldenTaskLoader {

    public enum LoadError: Error, CustomStringConvertible {
        case decodeFailed(URL, Error)
        case directoryMissing(URL)

        public var description: String {
            switch self {
            case .decodeFailed(let url, let error):
                return "failed to decode \(url.lastPathComponent): \(error)"
            case .directoryMissing(let url):
                return "fixture directory not found: \(url.path)"
            }
        }
    }

    /// Decodes a single fixture from `url`.
    public static func load(from url: URL) throws -> GoldenTaskFixture {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.decodeFailed(url, error)
        }
        do {
            return try JSONDecoder().decode(GoldenTaskFixture.self, from: data)
        } catch {
            throw LoadError.decodeFailed(url, error)
        }
    }

    /// Decodes every `*.json` file directly inside `directory` (non-recursive),
    /// sorted by filename for stable output.
    public static func loadAll(from directory: URL) throws -> [GoldenTaskFixture] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw LoadError.directoryMissing(directory)
        }
        let urls = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { try load(from: $0) }
    }
}
