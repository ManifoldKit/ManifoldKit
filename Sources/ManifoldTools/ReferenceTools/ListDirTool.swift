import Foundation
import ManifoldInference

/// Lists the non-hidden filenames inside the manifold-tools sandbox directory.
///
/// Same sandbox rules as ``ReadFileTool`` — `dir` is resolved against the
/// fixtures root and symlink-escape attempts return `.permissionDenied`.
public enum ListDirTool {

    public struct Args: Decodable, Sendable {
        public let dir: String
    }

    public struct Result: Encodable, Sendable {
        public let dir: String
        public let entries: [String]
    }

    public static func makeExecutor(root: URL = ReadFileTool.defaultRoot()) -> any ToolExecutor {
        let definition = ToolDefinition(
            name: "list_dir",
            description: "Lists non-hidden filenames inside a fixtures-sandbox directory.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "dir": .object([
                        "type": .string("string"),
                        "description": .string("Relative directory inside the fixtures sandbox. Use \".\" for the sandbox root.")
                    ])
                ]),
                "required": .array([.string("dir")])
            ])
        )
        return ListDirExecutor(definition: definition, root: root)
    }

    struct ListDirExecutor: ToolExecutor {
        let definition: ToolDefinition
        let root: URL

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            let data = try JSONEncoder().encode(arguments)
            let args = try JSONDecoder().decode(Args.self, from: data)

            guard let resolved = SandboxResolver.resolve(path: args.dir, inside: root) else {
                return ToolResult(
                    callId: "",
                    content: "path escapes sandbox: \(args.dir)",
                    errorKind: .permissionDenied
                )
            }

            guard FileManager.default.fileExists(atPath: resolved.path) else {
                return ToolResult(
                    callId: "",
                    content: "no such directory: \(args.dir)",
                    errorKind: .notFound
                )
            }

            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: resolved.path)
                    .filter { !$0.hasPrefix(".") }
                    .sorted()
                let payload = Result(dir: args.dir, entries: names)
                let encoded = try JSONEncoder().encode(payload)
                return ToolResult(
                    callId: "",
                    content: String(data: encoded, encoding: .utf8) ?? "",
                    errorKind: nil
                )
            } catch {
                return ToolResult(
                    callId: "",
                    content: "list failed: \(error)",
                    errorKind: .permanent
                )
            }
        }
    }
}
