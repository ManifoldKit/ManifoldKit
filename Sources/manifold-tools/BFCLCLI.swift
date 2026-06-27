import Foundation
import ManifoldInference
import ManifoldOllama
import ManifoldTools

/// `manifold-tools bfcl` — drives the bundled BFCL `simple` slice through a real
/// Ollama model and scores each emitted tool call at the **argument level** with
/// ``ASTMatcher``, contrasting it against what the name-only ``ConformanceScorer``
/// would have credited.
///
/// This is the spike's tangible demonstration: it runs the same prompts through
/// the production tool-injection path (`InferenceService` →
/// `GenerationToolDispatchLoop`, the only path that renders tools into the
/// prompt, #1983), captures the first emitted call, and shows the gap between
/// "called the right function" (name-only) and "called it with the right
/// arguments" (AST).
///
/// Single-turn by design: an empty registry plus `maxToolIterations: 1` means we
/// observe the model's first call and score it — we never execute the tool (BFCL
/// `simple` has no execution semantics).
enum BFCLCLI {

    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        var models = ["llama3.1-8b:latest"]
        var baseURL = URL(string: "http://localhost:11434")!
        var category = "multiple"

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--model":
                if i + 1 < args.count {
                    models = args[i + 1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                    i += 1
                }
            case "--category":
                if i + 1 < args.count {
                    category = args[i + 1]
                    i += 1
                }
            case "--ollama-base-url":
                if i + 1 < args.count, let url = URL(string: args[i + 1]) {
                    baseURL = url
                    i += 1
                }
            case "-h", "--help":
                print("usage: manifold-tools bfcl [--category simple|multiple] [--model a,b] [--ollama-base-url URL]")
                return 0
            default:
                FileHandle.standardError.write(Data("unknown flag '\(args[i])'\n".utf8))
                return 1
            }
            i += 1
        }

        let cases: [BFCLLoadedCase]
        do {
            cases = try BFCLCaseLoader.loadBundled(category: category)
        } catch {
            FileHandle.standardError.write(Data("failed to load BFCL '\(category)' cases: \(error)\n".utf8))
            return 1
        }
        print("BFCL category: \(category)")

        var anyModelFailed = false
        for model in models {
            do {
                try await runModel(model, baseURL: baseURL, category: category, cases: cases)
            } catch {
                anyModelFailed = true
                print("  ERROR loading (\(model)): \(error)")
            }
        }
        return anyModelFailed ? 1 : 0
    }

    @MainActor
    private static func runModel(_ model: String, baseURL: URL, category: String, cases: [BFCLLoadedCase]) async throws {
        let ollama = OllamaBackend(_registrar: ())
        ollama.configure(baseURL: baseURL, modelName: model)
        // A backend load failure is fatal for this model (no point scoring) and
        // throws to the caller; per-case generation errors below are not.
        try await ollama.loadModel(from: baseURL, plan: .cloud())
        // Empty registry: we capture the model's first tool call and score it; we
        // never dispatch/execute it. Tools are advertised via GenerationConfig.
        let service = InferenceService(backend: ollama, name: "ollama", modelName: model, toolRegistry: ToolRegistry())

        print("\nBFCL \(category) — ollama/\(model)  (\(cases.count) cases)")

        var astMatched = 0
        var nameMatched = 0
        var errored = 0
        for testCase in cases {
            let id = testCase.id.padding(toLength: 13, withPad: " ", startingAt: 0)

            // A single case erroring (e.g. a backend 500 on malformed tool output)
            // must not abort the whole model run — count it and continue.
            let calls: [ToolCall]
            do {
                calls = try await emittedCalls(for: testCase, service: service)
            } catch {
                errored += 1
                print("  ⚠ \(id) <error: \(shortError(error))>")
                continue
            }

            let score = ASTMatcher.scoreCase(emittedCalls: calls, groundTruth: testCase.groundTruth)
            let nameOK = calls.contains { call in
                testCase.groundTruth.contains { $0.functionName == call.toolName }
            }
            if score.matched { astMatched += 1 }
            if nameOK { nameMatched += 1 }

            let marker = score.matched ? "✓" : "✗"
            let emitted = calls.first.map { "\($0.toolName) \($0.arguments)" } ?? "<no tool call>"
            var line = "  \(marker) \(id) \(emitted)"
            if !score.matched, let reason = score.bestFailures.first {
                // Name matched but arguments wrong → exactly the gap the name-only
                // scorer misses. Surface why.
                line += "   ↳ \(reason)"
            }
            print(line)
        }

        let total = cases.count
        print("  ───")
        print("  AST accuracy (right function + right arguments): \(astMatched)/\(total) (\(pct(astMatched, total)))")
        print("  Name-only (what ConformanceScorer credits):      \(nameMatched)/\(total) (\(pct(nameMatched, total)))")
        let gap = nameMatched - astMatched
        if gap > 0 {
            print("  → \(gap) case(s) called the right tool with WRONG arguments — invisible to the name-only scorer.")
        }
        if errored > 0 {
            print("  (\(errored) case(s) errored at the backend and were not scored.)")
        }
    }

    /// Trims a backend error to a single readable line for the per-case row.
    private static func shortError(_ error: Error) -> String {
        let full = "\(error)"
        return full.count > 120 ? String(full.prefix(120)) + "…" : full
    }

    /// Drives one case through the production path and returns the tool calls the
    /// model emitted on its first turn.
    @MainActor
    private static func emittedCalls(for testCase: BFCLLoadedCase, service: InferenceService) async throws -> [ToolCall] {
        let messages = [StructuredMessage(role: "user", content: testCase.prompt)]
        let config = GenerationConfig(
            temperature: 0.0,
            topP: 0.9,
            repeatPenalty: 1.1,
            topK: 1,
            typicalP: nil,
            maxOutputTokens: 512,
            tools: testCase.tools,
            toolChoice: .auto,
            maxThinkingTokens: nil,
            jsonMode: false,
            thinkingMarkers: nil,
            maxToolIterations: 1
        )
        let (_, stream) = try service.enqueue(structuredMessages: messages, systemPrompt: "", config: config)

        var calls: [ToolCall] = []
        for try await event in stream.events {
            if case .toolCall(let call) = event {
                calls.append(call)
            }
        }
        return calls
    }

    private static func pct(_ n: Int, _ d: Int) -> String {
        guard d > 0 else { return "—" }
        return String(format: "%.1f%%", Double(n) / Double(d) * 100)
    }
}
