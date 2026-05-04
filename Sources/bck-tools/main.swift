// Does not require the Fuzz trait. The Ollama path is gated behind the
// `Ollama` trait (default-on for now); pass `--disable-default-traits`
// to drop it. The mock path is always available.
// For generation fuzzing with real backends, see scripts/fuzz.sh.
//
// The body is gated on the `Tools` trait. Without the trait, the executable
// links to a no-op stub that prints a "trait not enabled" message — this
// mirrors the BaseChatServer trait pattern (PR #946) and keeps `bck-tools`
// out of the default-trait build's link graph for the BaseChatTools and
// BaseChatBackends symbols.
#if Tools
import Foundation
import BaseChatInference
import BaseChatBackends
import BaseChatTools

/// Hand-rolled argument parser — `swift-argument-parser` would be the right
/// call in a larger CLI, but pulling in an external SPM dependency for a
/// 100-line harness is not worth the Package.swift churn. The syntax is small
/// enough to parse in place.
struct CLI {

    enum BackendChoice: String {
        case ollama
        case mock
    }

    var scenarioFilter: String = "all"
    var backend: BackendChoice = .ollama
    var modelOverrides: [String] = []
    var output: URL = defaultOutputURL()
    var list: Bool = false
    var realNetwork: Bool = false
    var ollamaBaseURL: URL = URL(string: "http://localhost:11434")!

    static func defaultOutputURL() -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return cwd.appendingPathComponent("tmp/bck-tools/\(TranscriptLogger.defaultFilename())")
    }

    /// Argument errors exit with status 2. We use `exit(2)` + stderr rather
    /// than `precondition` / `fatalError` because those trap with SIGABRT in
    /// debug builds, producing a confusing stack trace instead of the clean
    /// "bad arguments" exit code the usage text documents.
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("bck-tools: \(message)\n".utf8))
        exit(2)
    }

    static func parse(_ argv: [String]) -> CLI {
        var cli = CLI()
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "--scenario":
                i += 1
                guard i < argv.count else { fail("--scenario requires a value") }
                cli.scenarioFilter = argv[i]
            case "--backend":
                i += 1
                guard i < argv.count else { fail("--backend requires a value") }
                guard let b = BackendChoice(rawValue: argv[i]) else {
                    fail("unknown backend '\(argv[i])' — must be ollama or mock")
                }
                cli.backend = b
            case "--model":
                i += 1
                guard i < argv.count else { fail("--model requires a value") }
                cli.modelOverrides = argv[i].split(separator: ",").map(String.init)
            case "--output":
                i += 1
                guard i < argv.count else { fail("--output requires a value") }
                cli.output = URL(fileURLWithPath: argv[i])
            case "--list":
                cli.list = true
            case "--real-network":
                cli.realNetwork = true
            case "--ollama-base-url":
                i += 1
                guard i < argv.count else { fail("--ollama-base-url requires a value") }
                guard let u = URL(string: argv[i]), let scheme = u.scheme, !scheme.isEmpty else {
                    fail("--ollama-base-url value '\(argv[i])' is not a valid URL (missing scheme?)")
                }
                cli.ollamaBaseURL = u
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                fail("unknown argument: \(arg)")
            }
            i += 1
        }
        return cli
    }

    static func printUsage() {
        let text = """
        bck-tools — end-to-end tool-calling validation harness

        USAGE
          bck-tools [--scenario <id|all>] [--backend ollama|mock] [--model A,B]
                    [--output path.jsonl] [--real-network] [--list]

        FLAGS
          --scenario <id>       Scenario id (matches JSON 'id') or 'all'. Default: all.
          --backend <kind>      'ollama' (default) or 'mock' (offline, scripted).
          --model <list>        Comma-separated model overrides; each scenario runs once per model.
          --output <path>       Transcript JSONL destination. Default: tmp/bck-tools/<iso>.jsonl.
          --real-network        Allow HttpGetFixtureTool to hit the real internet (requires
                                BCK_TOOLS_ALLOW_NETWORK=1). Default: off.
          --ollama-base-url     Override the Ollama base URL. Default: http://localhost:11434.
          --list                Print available scenarios and exit.
          --help                Show this text.

        EXIT
          0 — all scenarios passed.
          1 — at least one scenario or assertion failed.
          2 — bad arguments.

        The transcript is one JSONL line per event (prompt / tool_call / tool_result /
        token_delta / final / assertion) so downstream tooling can diff runs without
        parsing free-form stdout.
        """
        print(text)
    }
}

@MainActor
func runCLI() async -> Int32 {
    let argv = Array(CommandLine.arguments.dropFirst())
    let cli = CLI.parse(argv)

    let scenarios: [Scenario]
    do {
        scenarios = try ScenarioLoader.loadBuiltIn()
    } catch {
        FileHandle.standardError.write(Data("failed to load scenarios: \(error)\n".utf8))
        return 1
    }

    if cli.list {
        print("Available scenarios:")
        for s in scenarios {
            print("  \(s.id) — \(s.description)")
        }
        return 0
    }

    let filtered: [Scenario]
    if cli.scenarioFilter == "all" {
        filtered = scenarios
    } else {
        filtered = scenarios.filter { $0.id == cli.scenarioFilter }
        if filtered.isEmpty {
            FileHandle.standardError.write(Data("no scenario matches id '\(cli.scenarioFilter)'\n".utf8))
            return 1
        }
    }

    let logger: TranscriptLogger
    do {
        logger = try TranscriptLogger(url: cli.output)
    } catch {
        FileHandle.standardError.write(Data("failed to open log: \(error)\n".utf8))
        return 1
    }
    print("Logging to \(logger.destination.path)")

    let registry = ToolRegistry()
    registry.register(NowTool.makeExecutor())
    registry.register(CalcTool.makeExecutor())
    registry.register(ReadFileTool.makeExecutor())
    registry.register(ListDirTool.makeExecutor())
    registry.register(HttpGetFixtureTool.makeExecutor(allowRealNetwork: cli.realNetwork))

    var allPassed = true
    for scenario in filtered {
        let models = cli.modelOverrides.isEmpty ? [scenario.backend.model] : cli.modelOverrides
        for model in models {
            print("\n── \(scenario.id) via \(cli.backend.rawValue)/\(model) ──")
            do {
                let backend = try await makeBackend(cli: cli, scenario: scenario, model: model)
                let runner = ScenarioRunner(backend: backend, registry: registry, logger: logger)
                let outcome = try await runner.run(scenario)
                for assertion in outcome.assertions {
                    let marker = assertion.passed ? "  PASS" : "  FAIL"
                    print("\(marker) \(assertion.message)")
                }
                if !outcome.passed {
                    allPassed = false
                    print("  final answer: \(outcome.finalAnswer.prefix(200))")
                }
            } catch {
                allPassed = false
                print("  ERROR \(error)")
            }
        }
    }

    if allPassed {
        print("\nAll scenarios passed.")
        return 0
    } else {
        print("\nOne or more scenarios failed — see \(logger.destination.path)")
        return 1
    }
}

@MainActor
func makeBackend(cli: CLI, scenario: Scenario, model: String) async throws -> any InferenceBackend {
    switch cli.backend {
    case .mock:
        return MockFactory.make(for: scenario)
    case .ollama:
        #if Ollama
        // FIXME(#714): expected deprecation warning until the next major
        // release flips `Ollama` out of default traits. bck-tools is internal
        // infrastructure that intentionally exercises the trait-gated init
        // directly.
        let backend = OllamaBackend()
        backend.configure(baseURL: cli.ollamaBaseURL, modelName: model)
        try await backend.loadModel(from: cli.ollamaBaseURL, plan: .cloud())
        return backend
        #else
        struct OllamaUnavailable: Error, CustomStringConvertible { var description: String { "Ollama backend not available — rebuild with the `Ollama` trait enabled (e.g. `swift build --traits Ollama`)." } }
        throw OllamaUnavailable()
        #endif
    }
}

enum MockFactory {
    /// Builds a `ScriptedBackend` pre-wired with a two-turn conversation that
    /// exercises the scenario's assertion: turn 1 emits the scripted tool
    /// call; turn 2 quotes a canned answer the runner treats as the final
    /// response.
    @MainActor
    static func make(for scenario: Scenario) -> ScriptedBackend {
        let toolName = scenario.requiredTools.first ?? "now"
        let args: String
        let finalAnswer: String
        switch toolName {
        case "calc":
            args = #"{"a":7823,"op":"*","b":41}"#
            finalAnswer = "320743"
        case "read_file":
            args = #"{"path":"example.txt"}"#
            finalAnswer = "NONCE-example-2026-04-22"
        case "list_dir":
            args = #"{"dir":"."}"#
            finalAnswer = "a.txt b.txt c.txt example.txt"
        default:
            args = "{}"
            finalAnswer = "2099-01-01T00:00:00Z"
        }
        return ScriptedBackend(turns: [
            .toolCall(name: toolName, arguments: args),
            .tokens([finalAnswer])
        ])
    }
}

let exitCode = await runCLI()
exit(exitCode)
#else
import Foundation
print("bck-tools was built without the `Tools` trait. Re-build with `--traits Tools` to enable.")
exit(0)
#endif
