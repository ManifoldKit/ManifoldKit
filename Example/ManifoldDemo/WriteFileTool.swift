import Foundation
import ManifoldInference
import ManifoldTools

/// Writes a UTF-8 text file inside the demo's sandbox directory.
///
/// Demo-local on purpose: this is a side-effecting primitive whose safety
/// story depends entirely on the sandbox root the host configures. Lifting it
/// into `ManifoldTools` would invite consumers to wire it without that root
/// and footgun themselves. If a real consumer asks, promote it explicitly
/// with a documented contract.
///
/// Sandbox policy mirrors ``ReadFileTool`` / ``ListDirTool``:
/// - `path` must be relative.
/// - Path traversal (`..`) and symlink escapes return `.permissionDenied`.
/// - The parent directory is created on demand.
///
/// `requiresApproval` is `true` so the orchestrator routes the call through
/// the `ToolApprovalGate` before the file lands on disk — exercising the
/// approval-flow demo scenario.
enum WriteFileTool {

    struct Args: Decodable, Sendable {
        let path: String
        let content: String
    }

    struct Result: Encodable, Sendable {
        let path: String
        let bytesWritten: Int
    }

    static func makeExecutor(root: URL) -> any ToolExecutor {
        let definition = ToolDefinition(
            name: "write_file",
            description: "Writes a UTF-8 text file inside the demo sandbox. Path must be relative to the sandbox root. Creates parent directories on demand. Requires explicit user approval.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path inside the demo sandbox.")
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("UTF-8 text to write.")
                    ])
                ]),
                "required": .array([.string("path"), .string("content")])
            ])
        )
        return WriteFileExecutor(definition: definition, root: root)
    }

    private struct WriteFileExecutor: ToolExecutor {
        let definition: ToolDefinition
        let root: URL

        var requiresApproval: Bool { true }

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

            do {
                try FileManager.default.createDirectory(
                    at: resolved.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let payload = Data(args.content.utf8)
                try payload.write(to: resolved, options: .atomic)
                let result = Result(path: args.path, bytesWritten: payload.count)
                let encoded = try JSONEncoder().encode(result)
                return ToolResult(
                    callId: "",
                    content: String(data: encoded, encoding: .utf8) ?? "",
                    errorKind: nil
                )
            } catch {
                return ToolResult(
                    callId: "",
                    content: "write failed: \(error)",
                    errorKind: .permanent
                )
            }
        }
    }
}
