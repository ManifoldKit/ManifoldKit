#if Tools && (Ollama || CloudSaaS || canImport(FoundationModels))
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

@MainActor
struct DemoScenarioE2EHarness {
    let backend: any InferenceBackend
    let backendName: String
    let modelName: String

    func runAndAssert(
        _ spec: DemoScenarioE2ESpec,
        registry: ToolRegistry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> DemoScenarioE2EResult {
        let result = try await run(spec, registry: registry)

        XCTAssertFalse(
            result.dispatchedCalls.isEmpty,
            "Scenario must invoke at least one tool.\n\(result.diagnostics)",
            file: file,
            line: line
        )
        XCTAssertFalse(
            result.finalText.isEmpty,
            "Scenario must produce a non-empty visible answer.\n\(result.diagnostics)",
            file: file,
            line: line
        )
        if !spec.expectedToolNames.isEmpty {
            if spec.allowsAdditionalToolCalls {
                let actualNames = result.dispatchedCalls.map(\.toolName)
                XCTAssertTrue(
                    actualNames.starts(with: spec.expectedToolNames),
                    "Scenario should start with the expected tool calls.\n\(result.diagnostics)",
                    file: file,
                    line: line
                )
                XCTAssertTrue(
                    actualNames.allSatisfy { spec.expectedToolNames.contains($0) },
                    "Scenario should not dispatch unexpected tool names.\n\(result.diagnostics)",
                    file: file,
                    line: line
                )
            } else {
                XCTAssertEqual(
                    result.dispatchedCalls.map(\.toolName),
                    spec.expectedToolNames,
                    "Scenario should dispatch exactly the expected tool calls in order.\n\(result.diagnostics)",
                    file: file,
                    line: line
                )
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
            let stream: GenerationStream
            if let receiver = backend as? ToolCallingHistoryReceiver {
                receiver.setToolAwareHistory(history)
                stream = try backend.generate(prompt: "", systemPrompt: nil, config: config)
            } else {
                stream = try backend.generate(
                    prompt: transcriptPrompt(from: history),
                    systemPrompt: spec.systemPrompt,
                    config: config
                )
            }

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

    private func transcriptPrompt(from history: [ToolAwareHistoryEntry]) -> String {
        let body = history.map { entry -> String in
            if let toolCallId = entry.toolCallId {
                return "tool_result id=\(toolCallId): \(entry.content)"
            }
            if let toolCalls = entry.toolCalls, !toolCalls.isEmpty {
                let calls = toolCalls
                    .map { "\($0.toolName)(id:\($0.id), arguments:\($0.arguments))" }
                    .joined(separator: "\n")
                return "assistant tool_calls:\n\(calls)"
            }
            return "\(entry.role): \(entry.content)"
        }.joined(separator: "\n\n")
        return """
        Continue this tool-calling transcript. If a tool result is present, answer the original user using the tool-derived facts. Otherwise call the required tool.

        \(body)
        """
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

enum DemoScenarioMeetingNotes {
    static let requiredFinalFacts = ["Riley", "Friday", "Security review"]

    static var spec: DemoScenarioE2ESpec {
        DemoScenarioE2ESpec(
            id: "meeting-notes-cross-backend",
            systemPrompt: """
            You are validating ManifoldKit demo tool calling. Use exactly the `meeting_notes_lookup` tool with meeting_id `beta-launch-sync` and include_decisions true. After the tool returns, answer in one concise sentence that includes the owner, ship decision, and blocker exactly from the tool result.
            """,
            userPrompt: "Summarize the BetaLaunch meeting note.",
            expectedToolNames: ["meeting_notes_lookup"],
            maxIterations: 4
        )
    }

    @MainActor
    static func makeRegistry() -> ToolRegistry {
        struct Args: Decodable, Sendable {
            let meeting_id: String
            let include_decisions: Bool
        }
        struct Result: Encodable, Sendable {
            let meeting_id: String
            let project: String
            let owner: String
            let decision: String
            let blocker: String
        }

        let registry = ToolRegistry()
        registry.register(TypedToolExecutor<Args, Result>(
            definition: ToolDefinition(
                name: "meeting_notes_lookup",
                description: "Looks up deterministic meeting notes by meeting_id. Pass include_decisions true when decisions are needed.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "meeting_id": .object([
                            "type": .string("string"),
                            "description": .string("Canonical meeting id, for example beta-launch-sync.")
                        ]),
                        "include_decisions": .object([
                            "type": .string("boolean"),
                            "description": .string("Whether to include decision and blocker facts.")
                        ]),
                    ]),
                    "required": .array([.string("meeting_id"), .string("include_decisions")])
                ])
            )
        ) { args in
            guard args.meeting_id == "beta-launch-sync", args.include_decisions else {
                throw NSError(
                    domain: "MeetingNotesTool",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "expected beta-launch-sync with include_decisions=true"]
                )
            }
            return Result(
                meeting_id: args.meeting_id,
                project: "BetaLaunch",
                owner: "Riley",
                decision: "Ship candidate Friday",
                blocker: "Security review"
            )
        })
        return registry
    }

    static func makeScriptedCall(id: String = "call-meeting-notes") -> ToolCall {
        ToolCall(
            id: id,
            toolName: "meeting_notes_lookup",
            arguments: #"{"meeting_id":"beta-launch-sync","include_decisions":true}"#
        )
    }

    static func assertContract(
        _ result: DemoScenarioE2EResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            result.dispatchedCalls.map(\.toolName),
            ["meeting_notes_lookup"],
            "Meeting-notes scenario should dispatch the shared tool path.\n\(result.diagnostics)",
            file: file,
            line: line
        )
        guard let call = result.dispatchedCalls.first, let trace = result.toolTraces.first else {
            XCTFail("Meeting-notes scenario did not dispatch a tool.\n\(result.diagnostics)", file: file, line: line)
            return
        }
        let normalizedArgs = call.arguments
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        XCTAssertTrue(normalizedArgs.contains(#""meeting_id":"beta-launch-sync""#), "Arguments must include meeting_id.\n\(result.diagnostics)", file: file, line: line)
        XCTAssertTrue(normalizedArgs.contains(#""include_decisions":true"#), "Arguments must include include_decisions=true.\n\(result.diagnostics)", file: file, line: line)
        for fact in requiredFinalFacts {
            XCTAssertTrue(trace.result.content.localizedCaseInsensitiveContains(fact), "Tool result must contain \(fact).\n\(result.diagnostics)", file: file, line: line)
            XCTAssertTrue(result.finalText.localizedCaseInsensitiveContains(fact), "Final answer must contain \(fact).\n\(result.diagnostics)", file: file, line: line)
        }
    }
}
#endif
