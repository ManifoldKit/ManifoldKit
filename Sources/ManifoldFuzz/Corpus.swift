import Foundation
import ManifoldInference

public struct CorpusEntry: Codable, Sendable, Identifiable {
    public var id: String
    public var category: String
    public var system: String?
    public var turns: [Turn]

    public struct Turn: Codable, Sendable {
        public var role: String
        public var text: String
    }
}

public enum Corpus {
    /// Named corpus subset. The default full corpus lives in `seeds.json`; the
    /// smoke subset in `smoke_seeds.json` is a small, deterministic set used by
    /// the PR-tier CI fuzz job where every mutator must exercise without
    /// relying on a real backend.
    public enum Subset: String, Sendable {
        case full
        case smoke

        /// Filename (sans extension) of the JSON resource backing this subset.
        public var resourceName: String {
            switch self {
            case .full: return "seeds"
            case .smoke: return "smoke_seeds"
            }
        }
    }

    /// Loads the default full corpus from `Resources/corpus/seeds.json`.
    public static func load() -> [CorpusEntry] {
        load(subset: .full)
    }

    /// Loads the named corpus subset. Failures are surfaced via `Log.inference`
    /// and stderr — callers (e.g. `FuzzRunner.run`) treat an empty corpus as a
    /// hard error rather than silently iterating zero times.
    public static func load(subset: Subset) -> [CorpusEntry] {
        let name = subset.resourceName
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            let msg = "Corpus.load: \(name).json missing from Bundle.module — Swift Package resource not bundled."
            Log.inference.error("\(msg, privacy: .public)")
            FileHandle.standardError.write(Data((msg + "\n").utf8))
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let msg = "Corpus.load: failed to read \(url.path): \(error)"
            Log.inference.error("\(msg, privacy: .public)")
            FileHandle.standardError.write(Data((msg + "\n").utf8))
            return []
        }
        do {
            return try JSONDecoder().decode([CorpusEntry].self, from: data)
        } catch {
            let msg = "Corpus.load: JSON decode failed for \(url.path): \(error)"
            Log.inference.error("\(msg, privacy: .public)")
            FileHandle.standardError.write(Data((msg + "\n").utf8))
            return []
        }
    }
}
