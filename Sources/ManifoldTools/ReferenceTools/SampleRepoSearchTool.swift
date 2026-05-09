import Foundation
import ManifoldInference

/// Literal-substring search across text files inside a sandbox directory.
///
/// Intended as the "hero" reference tool for demos: the model asks a question
/// about the contents of a folder, the tool returns a small set of matching
/// lines, and the model synthesises an answer that cites the files. Unlike
/// ``ReadFileTool`` / ``ListDirTool``, callers never pass a path — the search
/// is always rooted at the configured sandbox and cannot escape it.
///
/// ## Policy
///
/// - Literal, case-insensitive substring match. No regex — keeps the contract
///   obvious to the model and the cost bounded.
/// - Walks only regular files with text extensions (`.md`, `.txt`, `.swift`,
///   `.py`, `.js`, `.ts`, `.json`, `.yml`, `.yaml`). Hidden files skipped.
/// - Caps matches per file and overall to keep the tool's output small enough
///   for a single prompt iteration.
public enum SampleRepoSearchTool {

    public struct Args: Decodable, Sendable {
        public let query: String
        public let max_results: Int?
    }

    public struct Match: Codable, Sendable {
        public let path: String
        public let line: Int
        public let snippet: String
    }

    public struct Result: Codable, Sendable {
        public let matches: [Match]
        public let truncated: Bool
    }

    /// Hard cap on total matches the tool will return regardless of caller request.
    /// Set to keep single-turn tool output well under any reasonable context budget.
    public static let maxMatchesHardCap = 100

    /// Default match count when caller omits `max_results`.
    public static let defaultMaxMatches = 20

    /// Per-file match cap so one file cannot monopolise the result set.
    public static let perFileMatchCap = 5

    /// Extensions considered "text" — the walker skips everything else.
    public static let textExtensions: Set<String> = [
        "md", "txt", "swift", "py", "js", "ts", "json", "yml", "yaml",
    ]

    public static func makeExecutor(root: URL) -> any ToolExecutor {
        let definition = ToolDefinition(
            name: "sample_repo_search",
            description: "Searches text files in the user's workspace for a literal, case-insensitive substring. Returns the matching files, line numbers, and the matching line. Use this whenever the user asks what's in their files; never guess.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Substring to search for. Matched case-insensitively.")
                    ]),
                    "max_results": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of matches to return. Defaults to 20, capped at 100.")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        )
        return SampleRepoSearchExecutor(definition: definition, root: root)
    }

    struct SampleRepoSearchExecutor: ToolExecutor {
        let definition: ToolDefinition
        let root: URL

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            let data = try JSONEncoder().encode(arguments)
            let args = try JSONDecoder().decode(Args.self, from: data)

            let trimmed = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return ToolResult(
                    callId: "",
                    content: "query must not be empty",
                    errorKind: .invalidArguments
                )
            }

            let requested = args.max_results ?? defaultMaxMatches
            let limit = max(1, min(requested, maxMatchesHardCap))

            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else {
                return ToolResult(
                    callId: "",
                    content: "sandbox root does not exist: \(root.path)",
                    errorKind: .notFound
                )
            }

            let (matches, truncated) = walk(root: root, needle: trimmed.lowercased(), limit: limit)
            let result = Result(matches: matches, truncated: truncated)
            let encoded = try JSONEncoder().encode(result)
            return ToolResult(
                callId: "",
                content: String(data: encoded, encoding: .utf8) ?? "",
                errorKind: nil
            )
        }

        private func walk(root: URL, needle: String, limit: Int) -> (matches: [Match], truncated: Bool) {
            let fm = FileManager.default
            let rootPath = root.standardizedFileURL.path
            let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                return ([], false)
            }

            var matches: [Match] = []

            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }

                // Reject symlinks (and any other path trickery) that resolve outside
                // the sandbox root. Mirrors the containment contract in SandboxResolver
                // so this tool cannot be used to read arbitrary files on the host.
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
                let containmentPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                guard resolved == rootPath || resolved.hasPrefix(containmentPrefix) else { continue }

                let ext = url.pathExtension.lowercased()
                guard textExtensions.contains(ext) else { continue }

                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }

                let relativePath = relativize(url.standardizedFileURL.path, to: rootPath)

                var perFile = 0
                var lineNumber = 0
                for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                    lineNumber += 1
                    guard line.lowercased().contains(needle) else { continue }

                    matches.append(Match(path: relativePath, line: lineNumber, snippet: trimSnippet(String(line))))
                    perFile += 1

                    if matches.count >= limit {
                        return (matches, true)
                    }
                    if perFile >= perFileMatchCap { break }
                }
            }

            return (matches, false)
        }

        private func relativize(_ path: String, to rootPath: String) -> String {
            if path == rootPath { return "." }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
            return path
        }

        private func trimSnippet(_ line: String) -> String {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count <= 200 { return trimmed }
            return String(trimmed.prefix(200)) + "…"
        }
    }
}
