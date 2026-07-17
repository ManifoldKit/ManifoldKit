import Foundation
import XCTest
import ManifoldInference
import ManifoldTools

struct DemoScenarioE2ESpec: Sendable {
    let id: String
    let systemPrompt: String
    let userPrompt: String
    let expectedToolNames: [String]
    let maxIterations: Int
    let allowsAdditionalToolCalls: Bool

    init(
        id: String,
        systemPrompt: String,
        userPrompt: String,
        expectedToolNames: [String],
        maxIterations: Int = 4,
        allowsAdditionalToolCalls: Bool = false
    ) {
        self.id = id
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.expectedToolNames = expectedToolNames
        self.maxIterations = maxIterations
        self.allowsAdditionalToolCalls = allowsAdditionalToolCalls
    }
}

struct DemoScenarioE2EResult: Sendable {
    struct ToolTrace: Sendable {
        let call: ToolCall
        let result: ToolResult
    }

    let spec: DemoScenarioE2ESpec
    let backendName: String
    let modelName: String
    let advertisedToolNames: [String]
    let toolTraces: [ToolTrace]
    let finalText: String

    var dispatchedCalls: [ToolCall] {
        toolTraces.map(\.call)
    }

    var diagnostics: String {
        let trace = toolTraces.isEmpty
            ? "  <none>"
            : toolTraces.enumerated().map { index, item in
                """
                  [\(index)] tool=\(item.call.toolName)
                      args=\(item.call.arguments)
                      resultError=\(item.result.errorKind?.rawValue ?? "nil")
                      resultContent=\(item.result.content)
                """
            }.joined(separator: "\n")

        return """
        Demo scenario E2E failure
        scenario=\(spec.id)
        backend=\(backendName)
        model=\(modelName)
        expectedTools=\(spec.expectedToolNames)
        advertisedTools=\(advertisedToolNames)
        systemPrompt=\(spec.systemPrompt)
        userPrompt=\(spec.userPrompt)
        toolTrace:
        \(trace)
        finalText=\(finalText)
        """
    }
}

/// Thrown by `runAndAssert` when the dispatched tool calls don't match the
/// spec. XCTest's `XCTAssert*` family is non-fatal — it records a failure but
/// lets the test method fall through — so a caller that then indexes into
/// `result.dispatchedCalls[n]`/`result.toolTraces[n]` on the assumption the
/// assertion held crashes the whole test *process* on a short array
/// (`Fatal error: Index out of range`), taking every other suite in the
/// invocation down with it. Throwing here converts that into a clean,
/// single-test failure: the `XCTFail` still reports the failure at the
/// caller's file/line, and the throw makes every `try await
/// harness.runAndAssert(...)` call site short-circuit before any subscript
/// runs.
struct DemoScenarioAssertionFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
struct DemoScenarioE2EHarness {
    let backend: any InferenceBackend & ToolCallingHistoryReceiver
    let backendName: String
    let modelName: String

    func runAndAssert(
        _ spec: DemoScenarioE2ESpec,
        registry: ToolRegistry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> DemoScenarioE2EResult {
        let result = try await run(spec, registry: registry)

        func fail(_ message: String) -> DemoScenarioAssertionFailure {
            XCTFail(message, file: file, line: line)
            return DemoScenarioAssertionFailure(description: message)
        }

        guard !result.dispatchedCalls.isEmpty else {
            throw fail("Scenario must invoke at least one tool.\n\(result.diagnostics)")
        }
        guard !result.finalText.isEmpty else {
            throw fail("Scenario must produce a non-empty visible answer.\n\(result.diagnostics)")
        }
        if !spec.expectedToolNames.isEmpty {
            let actualNames = result.dispatchedCalls.map(\.toolName)
            if spec.allowsAdditionalToolCalls {
                guard actualNames.starts(with: spec.expectedToolNames) else {
                    throw fail("""
                        Scenario should start with the expected tool calls. \
                        expected=\(spec.expectedToolNames) actual=\(actualNames)
                        \(result.diagnostics)
                        """)
                }
                guard actualNames.allSatisfy({ spec.expectedToolNames.contains($0) }) else {
                    throw fail("""
                        Scenario should not dispatch unexpected tool names. \
                        expected=\(spec.expectedToolNames) actual=\(actualNames)
                        \(result.diagnostics)
                        """)
                }
            } else {
                guard actualNames == spec.expectedToolNames else {
                    throw fail("""
                        Scenario should dispatch exactly the expected tool calls in order. \
                        expected=\(spec.expectedToolNames) actual=\(actualNames)
                        \(result.diagnostics)
                        """)
                }
            }
        }

        return result
    }

    private func run(
        _ spec: DemoScenarioE2ESpec,
        registry: ToolRegistry
    ) async throws -> DemoScenarioE2EResult {
        var history: [ToolAwareHistoryEntry] = [
            ToolAwareHistoryEntry(role: "system", content: spec.systemPrompt),
            ToolAwareHistoryEntry(role: "user", content: spec.userPrompt),
        ]

        let definitions = registry.definitions
        let config = GenerationConfig(
            temperature: 0.2,
            topP: 1.0,
            maxOutputTokens: 256,
            tools: definitions,
            toolChoice: .auto,
            maxToolIterations: spec.maxIterations
        )

        var toolTraces: [DemoScenarioE2EResult.ToolTrace] = []
        var finalText = ""

        for _ in 0..<config.maxToolIterations {
            backend.setToolAwareHistory(history)
            let stream = try backend.generate(prompt: "", systemPrompt: nil, config: config)

            var turnCalls: [ToolCall] = []
            var turnText = ""
            for try await event in stream.events {
                switch event {
                case .toolCall(let call):
                    turnCalls.append(call)
                case .token(let text):
                    turnText += text
                default:
                    break
                }
            }

            if turnCalls.isEmpty {
                finalText = turnText
                break
            }

            history.append(ToolAwareHistoryEntry(role: "assistant", content: "", toolCalls: turnCalls))
            for call in turnCalls {
                let result = await registry.dispatch(call)
                toolTraces.append(DemoScenarioE2EResult.ToolTrace(call: call, result: result))
                history.append(ToolAwareHistoryEntry(role: "tool", content: result.content, toolCallId: call.id))
            }
        }

        return DemoScenarioE2EResult(
            spec: spec,
            backendName: backendName,
            modelName: modelName,
            advertisedToolNames: definitions.map(\.name).sorted(),
            toolTraces: toolTraces,
            finalText: finalText
        )
    }
}

enum DemoScenarioE2EFixtures {
    static func makeSandboxRoot(testName: String = "DemoScenarioOllamaE2ETests") throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent(testName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func makeCurrentTimeExecutor() -> any ToolExecutor {
        struct Args: Decodable, Sendable {
            let timezone: String?
        }
        struct Result: Encodable, Sendable {
            let timestamp: String
            let timezone: String
            let localTime: String
        }

        let definition = ToolDefinition(
            name: "now",
            description: "Returns the current date and time. If the user asks for a place-specific time, pass an IANA timezone like 'Asia/Tokyo' when possible; never guess.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "timezone": .object([
                        "type": .string("string"),
                        "description": .string("Optional IANA timezone identifier, for example 'Asia/Tokyo'.")
                    ])
                ]),
                "required": .array([])
            ])
        )

        return TypedToolExecutor<Args, Result>(definition: definition) { args in
            let timeZone = args.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
            let clock = ISO8601DateFormatter()
            clock.timeZone = timeZone

            let localFormatter = DateFormatter()
            localFormatter.locale = Locale(identifier: "en_US_POSIX")
            localFormatter.timeZone = timeZone
            localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"

            let now = Date()
            return Result(
                timestamp: clock.string(from: now),
                timezone: timeZone.identifier,
                localTime: localFormatter.string(from: now)
            )
        }
    }

    static func makeWriteFileExecutor(root: URL) -> any ToolExecutor {
        struct Args: Decodable, Sendable {
            let path: String
            let content: String
        }
        struct Result: Encodable, Sendable {
            let path: String
            let bytesWritten: Int
        }
        let definition = ToolDefinition(
            name: "write_file",
            description: "Writes a UTF-8 text file inside the sandbox. Relative path required.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "content": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("path"), .string("content")])
            ])
        )
        return TypedToolExecutor<Args, Result>(
            definition: definition,
            requiresApproval: false
        ) { args in
            guard let resolved = SandboxResolver.resolve(path: args.path, inside: root) else {
                throw NSError(
                    domain: "WriteFileTool",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "path escapes sandbox: \(args.path)"]
                )
            }
            try FileManager.default.createDirectory(
                at: resolved.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = Data(args.content.utf8)
            try payload.write(to: resolved, options: .atomic)
            return Result(path: args.path, bytesWritten: payload.count)
        }
    }
}
