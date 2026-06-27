import Foundation
import ManifoldInference
import ManifoldOllama
import ManifoldTools

/// `manifold-tools bfcl` — drives a bundled BFCL category slice (`simple` or
/// `multiple`, default `multiple`) through a real Ollama model and scores each
/// emitted tool call at the **argument level** with
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
        var dumpPath: String?
        var timeoutSeconds: Double = 120

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
            case "--dump":
                // Capture each scored case as JSONL for the offline canonical
                // `bfcl-eval` cross-check (see Sources/ManifoldTools/BFCL/BFCLDump.swift).
                if i + 1 < args.count {
                    dumpPath = args[i + 1]
                    i += 1
                }
            case "--timeout":
                if i + 1 < args.count, let t = Double(args[i + 1]), t > 0 {
                    timeoutSeconds = t
                    i += 1
                }
            case "-h", "--help":
                print("usage: manifold-tools bfcl [--category simple|multiple] [--model a,b] [--ollama-base-url URL] [--dump PATH.jsonl] [--timeout SECONDS]")
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
        var dumpRecords: [BFCLRunRecord] = []
        for model in models {
            do {
                dumpRecords += try await runModel(model, baseURL: baseURL, category: category, cases: cases, timeoutSeconds: timeoutSeconds)
            } catch {
                anyModelFailed = true
                print("  ERROR loading (\(model)): \(error)")
            }
        }

        if let dumpPath {
            do {
                let body = try dumpRecords.map { try $0.jsonLine() }.joined(separator: "\n")
                try (body + "\n").write(toFile: dumpPath, atomically: true, encoding: .utf8)
                print("\nWrote \(dumpRecords.count) case record(s) → \(dumpPath)")
            } catch {
                FileHandle.standardError.write(Data("failed to write dump to \(dumpPath): \(error)\n".utf8))
                return 1
            }
        }
        return anyModelFailed ? 1 : 0
    }

    /// Builds an Ollama-backed service for the model and delegates the per-case
    /// loop to the shared, backend-agnostic ``BFCLRunner``. Returns the capture
    /// records (one per scored case) for the offline cross-check dump.
    @MainActor
    private static func runModel(_ model: String, baseURL: URL, category: String, cases: [BFCLLoadedCase], timeoutSeconds: Double) async throws -> [BFCLRunRecord] {
        let ollama = OllamaBackend(_registrar: ())
        ollama.configure(baseURL: baseURL, modelName: model)
        // A backend load failure is fatal for this model (no point scoring) and
        // throws to the caller; per-case generation errors are not (BFCLRunner
        // counts and continues).
        try await ollama.loadModel(from: baseURL, plan: .cloud())
        // Empty registry: we capture the model's first tool call and score it; we
        // never dispatch/execute it. Tools are advertised via GenerationConfig.
        let service = InferenceService(backend: ollama, name: "ollama", modelName: model, toolRegistry: ToolRegistry())

        let outcome = await BFCLRunner().run(cases: cases, service: service, modelLabel: "ollama/\(model)", perCaseTimeoutSeconds: timeoutSeconds)
        return outcome.records
    }
}
