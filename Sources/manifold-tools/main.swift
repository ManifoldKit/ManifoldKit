// Does not require the Fuzz trait. The Ollama and mock paths are always
// available — the Ollama trait was retired in v0.48 (PR A4) and
// ManifoldOllama now compiles unconditionally.
// For generation fuzzing with real backends, see scripts/fuzz.sh.
//
// The `Tools` trait was retired in v0.48 (PR A3) — the CLI body compiles
// unconditionally now. It links the ManifoldOllama family product directly
// instead of the ManifoldBackends umbrella so MLX/llama.framework never
// enter the link graph (the #982 dual-llama Xcode-scheme hazard).
import Foundation
import ManifoldInference
import ManifoldTools
import ManifoldOllama

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
        return cwd.appendingPathComponent("tmp/manifold-tools/\(TranscriptLogger.defaultFilename())")
    }

    /// Argument errors exit with status 2. We use `exit(2)` + stderr rather
    /// than `precondition` / `fatalError` because those trap with SIGABRT in
    /// debug builds, producing a confusing stack trace instead of the clean
    /// "bad arguments" exit code the usage text documents.
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("manifold-tools: \(message)\n".utf8))
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
        manifold-tools — end-to-end tool-calling validation harness

        USAGE
          manifold-tools [--scenario <id|all>] [--backend ollama|mock] [--model A,B]
                    [--output path.jsonl] [--real-network] [--list]
          manifold-tools test-uplift status|pause|resume|stop

        FLAGS
          --scenario <id>       Scenario id (matches JSON 'id') or 'all'. Default: all.
          --backend <kind>      'ollama' (default) or 'mock' (offline, scripted).
          --model <list>        Comma-separated model overrides; each scenario runs once per model.
          --output <path>       Transcript JSONL destination. Default: tmp/manifold-tools/<iso>.jsonl.
          --real-network        Allow HttpGetFixtureTool to hit the real internet (requires
                                MANIFOLD_TOOLS_ALLOW_NETWORK=1). Default: off.
          --ollama-base-url     Override the Ollama base URL. Default: http://localhost:11434.
          --list                Print available scenarios and exit.
          --help                Show this text.

        SUBCOMMANDS
          test-uplift           Inspect or control ~/.claude/state/bck-test-uplift/.

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

enum TestUpliftCLI {
    private static let stateDirectory = ".claude/state/bck-test-uplift"

    static func run(_ argv: [String]) -> Int32 {
        guard let command = argv.first else {
            printUsage()
            return 0
        }
        guard command != "--help", command != "-h" else {
            printUsage()
            return 0
        }
        guard argv.count == 1 else {
            return fail("expected one of status, pause, resume, stop", code: 2)
        }

        switch command {
        case "status": return printStatus()
        case "pause": return writeControl("PAUSE")
        case "resume": return writeControl("RUN")
        case "stop": return writeControl("STOP")
        default: return fail("expected one of status, pause, resume, stop", code: 2)
        }
    }

    private static func printUsage() {
        let text = """
        manifold-tools test-uplift — inspect and control the overnight test-uplift orchestrator

        USAGE
          manifold-tools test-uplift status
          manifold-tools test-uplift pause|resume|stop

        STATE
          ~/.claude/state/bck-test-uplift/status.json
          ~/.claude/state/bck-test-uplift/control
        """
        print(text)
    }

    private static func printStatus() -> Int32 {
        let statusURL = stateURL().appendingPathComponent("status.json")
        guard FileManager.default.fileExists(atPath: statusURL.path) else {
            return fail("status file not found at \(statusURL.path)")
        }

        do {
            let data = try Data(contentsOf: statusURL)
            let json = try JSONSerialization.jsonObject(with: data)
            guard let status = json as? [String: Any] else {
                return fail("status file must contain a JSON object: \(statusURL.path)")
            }

            print("Test uplift status")
            print("State: \(stateURL().path)")
            print("Phase: \(stringValue(status, keys: ["current_phase", "currentPhase", "phase"]) ?? "unknown")")
            printSection("In-flight workers", value(status, keys: ["in_flight_workers", "inFlightWorkers", "in_flight", "inFlight", "workers"]))
            printSection("Queue", value(status, keys: ["queue", "queued", "pending"]))
            printSection("Blockers", value(status, keys: ["blockers", "blocked"]) ?? blockersTSV())
            return 0
        } catch {
            return fail("failed to read status: \(error)")
        }
    }

    private static func writeControl(_ value: String) -> Int32 {
        let directory = stateURL()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return fail("state directory not found at \(directory.path)")
        }

        let controlURL = directory.appendingPathComponent("control")
        do {
            try "\(value)\n".write(to: controlURL, atomically: true, encoding: .utf8)
            print("Wrote \(value) to \(controlURL.path)")
            return 0
        } catch {
            return fail("failed to write control file: \(error)")
        }
    }

    private static func stateURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent(stateDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(stateDirectory)
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data("manifold-tools test-uplift: \(message)\n".utf8))
        return code
    }

    private static func value(_ status: [String: Any], keys: [String]) -> Any? {
        for key in keys where status[key] != nil { return status[key] }
        return nil
    }

    private static func stringValue(_ status: [String: Any], keys: [String]) -> String? {
        guard let raw = value(status, keys: keys) else { return nil }
        if let string = raw as? String { return string }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    private static func blockersTSV() -> [String]? {
        let blockersURL = stateURL().appendingPathComponent("blockers.tsv")
        guard FileManager.default.fileExists(atPath: blockersURL.path) else { return nil }
        do {
            let text = try String(contentsOf: blockersURL, encoding: .utf8)
            return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        } catch {
            return ["failed to read \(blockersURL.path): \(error)"]
        }
    }

    private static func printSection(_ title: String, _ value: Any?) {
        print("\(title):")
        let rows = lines(value)
        if rows.isEmpty {
            print("  none")
        } else {
            for row in rows { print("  - \(row)") }
        }
    }

    private static func lines(_ value: Any?) -> [String] {
        guard let value else { return [] }
        if let array = value as? [Any] { return array.flatMap(lines) }
        if let dictionary = value as? [String: Any] {
            guard !dictionary.isEmpty else { return [] }
            let preferred = ["worker", "id", "branch", "pr", "status", "phase", "reason"]
            let keys = preferred.filter { dictionary[$0] != nil } + dictionary.keys.sorted().filter { !preferred.contains($0) }
            return [keys.map { "\($0)=\(describe(dictionary[$0] ?? ""))" }.joined(separator: " ")]
        }
        let text = describe(value)
        return text.isEmpty ? [] : [text]
    }

    private static func describe(_ value: Any) -> String {
        if let string = value as? String { return string }
        if value is NSNull { return "null" }
        if let number = value as? NSNumber { return number.stringValue }
        guard JSONSerialization.isValidJSONObject(value) else { return String(describing: value) }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? String(describing: value)
        } catch {
            return String(describing: value)
        }
    }
}

@MainActor
func runCLI() async -> Int32 {
    let argv = Array(CommandLine.arguments.dropFirst())
    if argv.first == "test-uplift" {
        return TestUpliftCLI.run(Array(argv.dropFirst()))
    }
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
    registry.register(SampleRepoSearchTool.makeExecutor(root: ReadFileTool.defaultRoot()))
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
        let backend = OllamaBackend(_registrar: ())
        backend.configure(baseURL: cli.ollamaBaseURL, modelName: model)
        try await backend.loadModel(from: cli.ollamaBaseURL, plan: .cloud())
        return backend
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
        if scenario.requiredTools.isEmpty {
            return ScriptedBackend(turns: [.tokens([MockFactory.toolFreeAnswer(for: scenario)])])
        }
        if scenario.id == "shopping-list-budget" {
            return ScriptedBackend(turns: [
                .toolCall(name: "read_file", arguments: #"{"path":"shopping-list.txt"}"#),
                .toolCall(name: "calc", arguments: #"{"a":12.5,"op":"+","b":7.25}"#),
                .tokens(["apples and rice cost 19.75; do not buy saffron."])
            ])
        }
        switch toolName {
        case "calc":
            args = #"{"a":7823,"op":"*","b":41}"#
            finalAnswer = "320743"
        case "read_file":
            if scenario.id == "parallel-readme-comparison" {
                return ScriptedBackend(turns: [
                    .mixed(tokens: [], toolCalls: [
                        (name: "read_file", arguments: #"{"path":"readmes/backend-a.md"}"#),
                        (name: "read_file", arguments: #"{"path":"readmes/backend-b.md"}"#)
                    ]),
                    .tokens(["Backend A uses streaming tools; Backend B uses batch tools. Both mention DEMO-README-NONCE."])
                ])
            } else if scenario.id == "oversize-tool-output" {
                args = #"{"path":"oversize-output.txt"}"#
                finalAnswer = "The tool output was too large and exceeded maxBytes, so I will ask for a narrower slice."
            } else {
                args = #"{"path":"example.txt"}"#
                finalAnswer = "NONCE-example-2026-04-22"
            }
        case "list_dir":
            if scenario.id == "meeting-notes-summary" {
                return ScriptedBackend(turns: [
                    .toolCall(name: "list_dir", arguments: #"{"dir":"notes"}"#),
                    .toolCall(name: "read_file", arguments: #"{"path":"notes/standup.md"}"#),
                    .tokens(["Aurora shipped the tool harness; Beacon is blocked on MCP credentials."])
                ])
            } else {
                args = #"{"dir":"."}"#
                finalAnswer = "a.txt b.txt c.txt example.txt"
            }
        default:
            args = "{}"
            finalAnswer = "2099-01-01T00:00:00Z"
        }
        return ScriptedBackend(turns: [
            .toolCall(name: toolName, arguments: args),
            .tokens([finalAnswer])
        ])
    }

    private static func toolFreeAnswer(for scenario: Scenario) -> String {
        if scenario.id == "structured-json-extraction" {
            return #"{"invoice_id":"INV-754-CORE","total":123.45,"currency":"USD"}"#
        }
        return ""
    }
}

let exitCode = await runCLI()
exit(exitCode)
