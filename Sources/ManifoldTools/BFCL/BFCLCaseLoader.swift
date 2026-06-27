import Foundation

/// Loads BFCL cases by joining a question file with its `possible_answer` file.
///
/// BFCL ships two parallel JSONL files keyed by a shared `id`: the questions
/// (prompt + advertised functions) and the ground truth (accepted calls). This
/// loader decodes both, joins them by id, and returns normalized
/// ``BFCLLoadedCase`` values ready to drive ``ScenarioRunner`` and score with
/// ``ASTMatcher``.
///
/// A small `simple`-category slice (Apache-2.0, see `fixtures/ATTRIBUTION.md`) is
/// vendored under `Sources/ManifoldTools/BFCL/fixtures` and resolves through
/// `Bundle.module` — the same package-resource pattern as the built-in scenario
/// corpus, so it loads identically under `swift test`, `swift run`, an installed
/// CLI, or a downstream consumer regardless of working directory.
public enum BFCLCaseLoader {

    public enum LoadError: Error, CustomStringConvertible {
        case resourceMissing(String)
        case fileUnreadable(URL, underlying: Error)
        case answerMissing(questionID: String)

        public var description: String {
            switch self {
            case .resourceMissing(let name):
                return "BFCL fixture resource not found in bundle: \(name)"
            case .fileUnreadable(let url, let underlying):
                return "BFCLCaseLoader: cannot read \(url.path): \(underlying)"
            case .answerMissing(let id):
                return "BFCL question '\(id)' has no matching ground-truth answer"
            }
        }
    }

    /// Loads a vendored BFCL category slice from the package resource bundle.
    ///
    /// Resolves `<category>_questions.jsonl` + `<category>_answers.jsonl` from the
    /// bundled `fixtures` directory. Vendored categories: `simple` (illustrative,
    /// hand-authored) and `multiple` (a verbatim subset of upstream
    /// `BFCL_v4_multiple`, Apache-2.0 — see `fixtures/ATTRIBUTION.md`).
    public static func loadBundled(category: String) throws -> [BFCLLoadedCase] {
        let questions = try bundledResource("\(category)_questions", ext: "jsonl")
        let answers = try bundledResource("\(category)_answers", ext: "jsonl")
        return try load(questionsFile: questions, answersFile: answers)
    }

    /// Loads the vendored `simple`-category slice. Thin wrapper over
    /// ``loadBundled(category:)`` retained for existing call sites.
    public static func loadBundledSimple() throws -> [BFCLLoadedCase] {
        try loadBundled(category: "simple")
    }

    /// Joins a question file with its answer file into normalized cases, sorted
    /// by id for stable output. A question without a matching answer is a fixture
    /// integrity error (the two files must stay in lockstep), so it throws rather
    /// than silently dropping the case.
    public static func load(questionsFile: URL, answersFile: URL) throws -> [BFCLLoadedCase] {
        let questions = try decodeLines(questionsFile, as: BFCLQuestionRecord.self)
        let answers = try decodeLines(answersFile, as: BFCLAnswerRecord.self)

        let answersByID = Dictionary(uniqueKeysWithValues: answers.map { ($0.id, $0) })

        var cases: [BFCLLoadedCase] = []
        for question in questions {
            guard let answer = answersByID[question.id] else {
                throw LoadError.answerMissing(questionID: question.id)
            }
            cases.append(
                BFCLLoadedCase(
                    id: question.id,
                    prompt: question.flattenedPrompt(),
                    tools: question.function.map { $0.toToolDefinition() },
                    groundTruth: answer.expectedCalls()
                )
            )
        }
        return cases.sorted { $0.id < $1.id }
    }

    // MARK: - Internals

    private static func bundledResource(_ name: String, ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "fixtures") else {
            throw LoadError.resourceMissing("fixtures/\(name).\(ext)")
        }
        return url
    }

    /// Decodes a JSONL file (one JSON object per line). Blank lines are skipped;
    /// a malformed line is fatal (unlike a transcript, a fixture must be clean).
    private static func decodeLines<T: Decodable>(_ url: URL, as type: T.Type) throws -> [T] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.fileUnreadable(url, underlying: error)
        }
        let text = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        var result: [T] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            result.append(try decoder.decode(T.self, from: lineData))
        }
        return result
    }
}
