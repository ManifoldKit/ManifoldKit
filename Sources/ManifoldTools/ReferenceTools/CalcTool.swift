import Foundation
import ManifoldInference

/// Numeric calculator — deterministic answer for the scripted arithmetic
/// scenarios. Returns an `.invalidArguments` error for `/` with `b == 0`
/// rather than silently producing `inf` / `nan`.
public enum CalcTool {

    public struct Args: Decodable, Sendable {
        public let a: Double
        public let op: String
        public let b: Double
    }

    public struct Result: Encodable, Sendable {
        public let answer: Double
    }

    public static func makeExecutor() -> any ToolExecutor {
        let definition = ToolDefinition(
            name: "calc",
            description: "Evaluates a single arithmetic expression of the form `a op b` where op is one of +, -, *, /. Call this for any numeric calculation; never perform arithmetic in your head.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "a": .object(["type": .string("number"), "description": .string("Left operand.")]),
                    "op": .object([
                        "type": .string("string"),
                        "enum": .array([.string("+"), .string("-"), .string("*"), .string("/")]),
                        "description": .string("Arithmetic operator.")
                    ]),
                    "b": .object(["type": .string("number"), "description": .string("Right operand.")])
                ]),
                "required": .array([.string("a"), .string("op"), .string("b")])
            ])
        )

        // Use a custom ToolExecutor so we can emit `.invalidArguments` on
        // division-by-zero (TypedToolExecutor can only signal errors by
        // throwing, which would be classified as `.permanent`).
        return CalcExecutor(definition: definition)
    }

    struct CalcExecutor: ToolExecutor {
        let definition: ToolDefinition

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            let data = try JSONEncoder().encode(arguments)
            let args = try JSONDecoder().decode(Args.self, from: data)

            let answer: Double
            switch args.op {
            case "+": answer = args.a + args.b
            case "-": answer = args.a - args.b
            case "*": answer = args.a * args.b
            case "/":
                if args.b == 0 {
                    return ToolResult(callId: "", content: "division by zero", errorKind: .invalidArguments)
                }
                answer = args.a / args.b
            default:
                return ToolResult(
                    callId: "",
                    content: "unknown operator '\(args.op)'",
                    errorKind: .invalidArguments
                )
            }

            let result = Result(answer: answer)
            let resultData = try JSONEncoder().encode(result)
            let content = String(data: resultData, encoding: .utf8) ?? ""
            return ToolResult(callId: "", content: content, errorKind: nil)
        }
    }
}
