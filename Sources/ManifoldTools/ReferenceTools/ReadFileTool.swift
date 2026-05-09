import Foundation
import ManifoldInference

/// Reads a single file from the manifold-tools sandbox directory.
///
/// Sandbox policy — the `path` argument is resolved against
/// `Tests/Fixtures/manifold-tools/` (or an explicit root provided to
/// ``makeExecutor(root:)``). Paths that escape the root after symlink
/// resolution return `.permissionDenied`. Missing files return `.notFound`.
public enum ReadFileTool {

    public struct Args: Decodable, Sendable {
        public let path: String
    }

    public struct Result: Encodable, Sendable {
        public let path: String
        public let content: String
    }

    /// Creates the executor with a sandbox root.
    ///
    /// - Parameter root: The directory reads are confined to. Defaults to
    ///   the repo-relative `Tests/Fixtures/manifold-tools/` — scenarios running
    ///   from `swift run manifold-tools` start in the package root so this
    ///   resolves correctly.
    public static func makeExecutor(root: URL = defaultRoot()) -> any ToolExecutor {
        let definition = ToolDefinition(
            name: "read_file",
            description: "Reads a file inside the fixtures sandbox and returns its UTF-8 contents. Path must be relative to the sandbox root.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path inside the fixtures sandbox.")
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        )
        return ReadFileExecutor(definition: definition, root: root)
    }

    /// Default sandbox root — `Tests/Fixtures/manifold-tools/` relative to the
    /// current working directory. Swift Package Manager invocations
    /// (`swift run`, `swift test`) set CWD to the package root.
    public static func defaultRoot() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures/manifold-tools", isDirectory: true)
    }

    struct ReadFileExecutor: ToolExecutor {
        let definition: ToolDefinition
        let root: URL

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            let data = try JSONEncoder().encode(arguments)
            let args = try JSONDecoder().decode(Args.self, from: data)

            guard let resolved = SandboxResolver.resolve(path: args.path, inside: root) else {
                return ToolResult(
                    callId: "",
                    content: "path escapes sandbox: \(args.path)",
                    errorKind: .permissionDenied
                )
            }

            guard FileManager.default.fileExists(atPath: resolved.path) else {
                return ToolResult(
                    callId: "",
                    content: "no such file: \(args.path)",
                    errorKind: .notFound
                )
            }

            do {
                let content = try String(contentsOf: resolved, encoding: .utf8)
                let payload = Result(path: args.path, content: content)
                let encoded = try JSONEncoder().encode(payload)
                return ToolResult(
                    callId: "",
                    content: String(data: encoded, encoding: .utf8) ?? "",
                    errorKind: nil
                )
            } catch {
                return ToolResult(
                    callId: "",
                    content: "read failed: \(error)",
                    errorKind: .permanent
                )
            }
        }
    }
}
