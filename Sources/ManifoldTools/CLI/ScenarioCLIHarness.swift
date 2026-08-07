import Foundation
import ManifoldInference

/// Shared shape for a scenario-driving CLI: the flag set, bundled scenario
/// loading, transcript-summary printing, and per-(scenario × model) run loop
/// that `manifold-tools` (this repo), `manifold-tools-mlx`, and
/// `manifold-tools-llama` had each hand-rolled near-identically.
///
/// Backend-specific behavior — how to load the model / build the
/// `InferenceBackend`, and how to build the per-scenario `ToolRegistry` — is
/// injected via closures (`runOne` / `modelsFor`) rather than owned here,
/// because tool-registry scoping (register every reference tool vs. scope to
/// `scenario.requiredTools`) and model-loading policy (one model per run vs.
/// one model per `--model` override) are genuine, intentional differences
/// across consumers, not drift to unify.
public enum ScenarioCLIHarness {

    // MARK: - Flag parsing

    /// Flags common to every scenario-CLI harness consumer.
    public struct Options: Sendable {
        public var scenarioFilter: String
        public var output: URL
        public var fixturesRoot: URL?
        public var extraTools: Int
        public var list: Bool
        /// Which repetition of an otherwise-identical (decoy level × scenario)
        /// cell this invocation represents. Threaded verbatim into every
        /// ``TranscriptLogger`` record this run writes (mirrors the existing
        /// per-record `backend`/`model`/`quant` attribution) so
        /// ``ConformanceScorer`` can recover it later instead of collating
        /// repeats by hand. Default `0` — a single, unrepeated run.
        public var repeatIndex: Int

        public init(
            scenarioFilter: String = "all",
            output: URL,
            fixturesRoot: URL? = nil,
            extraTools: Int = 0,
            list: Bool = false,
            repeatIndex: Int = 0
        ) {
            self.scenarioFilter = scenarioFilter
            self.output = output
            self.fixturesRoot = fixturesRoot
            self.extraTools = extraTools
            self.list = list
            self.repeatIndex = repeatIndex
        }

        /// Pre-`repeatIndex` signature, kept alongside the current initializer
        /// so `swift-api-digester` sees an addition rather than a removal.
        /// Source compatibility alone isn't enough here: adding a defaulted
        /// parameter to an existing public initializer still retires the old
        /// *interface* symbol the digester compares against, even though every
        /// existing call site keeps compiling (#2450 CI: `constructor
        /// ScenarioCLIHarness.Options.init(scenarioFilter:output:
        /// fixturesRoot:extraTools:list:) has been removed`). Swift resolves a
        /// call omitting `repeatIndex` to this narrower overload rather than
        /// defaulting it on the six-parameter one, so this isn't dead code.
        public init(
            scenarioFilter: String = "all",
            output: URL,
            fixturesRoot: URL? = nil,
            extraTools: Int = 0,
            list: Bool = false
        ) {
            self.init(
                scenarioFilter: scenarioFilter,
                output: output,
                fixturesRoot: fixturesRoot,
                extraTools: extraTools,
                list: list,
                repeatIndex: 0
            )
        }
    }

    /// Result of ``parseCommonFlags(_:defaultOutput:)``.
    public enum ParseOutcome {
        /// Parsed successfully. `remainder` carries every argument this
        /// parser didn't recognise, in original order, for the caller to
        /// parse its own backend-specific flags (`--backend`, `--model`,
        /// `--ollama-base-url`, …).
        case options(Options, remainder: [String])
        /// `--help`/`-h` was present — the caller should print its own usage
        /// text (which documents both the common and backend-specific flags)
        /// and exit 0.
        case helpRequested
        /// A recognised flag was missing its required value, or had an
        /// invalid one. The caller should print this to stderr and exit 2.
        case failure(String)
    }

    /// Parses `--scenario`, `--output`, `--fixtures-root`, `--extra-tools`,
    /// `--repeat-index`, `--list`, and `--help`/`-h`. Any other token — flag or value — is
    /// appended to `remainder` untouched, so a caller with its own additional
    /// flags can run a second pass over `remainder` to parse them, regardless
    /// of how the two flag sets are interleaved on the command line (each
    /// flag here is self-describing and consumes exactly its own value).
    public static func parseCommonFlags(
        _ argv: [String],
        defaultOutput: @autoclosure () -> URL
    ) -> ParseOutcome {
        var options = Options(output: defaultOutput())
        var remainder: [String] = []
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "--scenario":
                i += 1
                guard i < argv.count else { return .failure("--scenario requires a value") }
                options.scenarioFilter = argv[i]
            case "--output":
                i += 1
                guard i < argv.count else { return .failure("--output requires a value") }
                options.output = URL(fileURLWithPath: argv[i])
            case "--fixtures-root":
                i += 1
                guard i < argv.count else { return .failure("--fixtures-root requires a value") }
                options.fixturesRoot = URL(fileURLWithPath: argv[i], isDirectory: true)
            case "--extra-tools":
                i += 1
                guard i < argv.count else { return .failure("--extra-tools requires a value") }
                guard let n = Int(argv[i]), n >= 0 else {
                    return .failure("--extra-tools value '\(argv[i])' must be a non-negative integer")
                }
                options.extraTools = n
            case "--repeat-index":
                i += 1
                guard i < argv.count else { return .failure("--repeat-index requires a value") }
                guard let n = Int(argv[i]), n >= 0 else {
                    return .failure("--repeat-index value '\(argv[i])' must be a non-negative integer")
                }
                options.repeatIndex = n
            case "--list":
                options.list = true
            case "--help", "-h":
                return .helpRequested
            default:
                remainder.append(arg)
            }
            i += 1
        }
        return .options(options, remainder: remainder)
    }

    // MARK: - Scenario loading

    public enum FilterError: Error, CustomStringConvertible {
        case noMatch(String)

        public var description: String {
            switch self {
            case .noMatch(let id):
                return "no scenario matches id '\(id)' — run --list for valid IDs"
            }
        }
    }

    /// Filters `scenarios` to `filter`, or returns them unchanged when
    /// `filter == "all"`. Throws ``FilterError/noMatch(_:)`` when `filter`
    /// names an id absent from `scenarios`.
    public static func filterScenarios(_ scenarios: [Scenario], matching filter: String) throws -> [Scenario] {
        guard filter != "all" else { return scenarios }
        let filtered = scenarios.filter { $0.id == filter }
        guard !filtered.isEmpty else { throw FilterError.noMatch(filter) }
        return filtered
    }

    // MARK: - Fixtures root

    /// Resolves the sandbox root for `read_file` / `list_dir` /
    /// `sample_repo_search`: an explicit `--fixtures-root` override, else the
    /// fixture tree bundled with `ManifoldTools` (``ToolFixtures/bundledRoot()``).
    public static func resolveFixturesRoot(_ override: URL?) -> URL {
        override ?? ToolFixtures.bundledRoot()
    }

    // MARK: - Run loop

    /// Runs every scenario in `scenarios` against the model(s) `modelsFor`
    /// selects for it, printing PASS/FAIL per assertion and tracking the
    /// aggregate pass/fail outcome — the loop body every hand-rolled CLI main
    /// duplicated. `runOne` performs the backend-specific work (build the
    /// registry, load/reuse the backend, construct the `InferenceService`,
    /// drive `ScenarioRunner`) and returns its ``ScenarioRunner/Outcome``.
    ///
    /// Errors thrown by `runOne` (e.g. the backend rejecting a nonexistent
    /// model) are caught, printed to stderr in the shared format, and counted
    /// as a failure — they never propagate, so one bad (scenario, model)
    /// pair never aborts the rest of the sweep.
    @MainActor
    public static func runAll(
        scenarios: [Scenario],
        displayName: String,
        modelsFor: (_ scenario: Scenario) -> [String],
        runOne: @MainActor (_ scenario: Scenario, _ model: String) async throws -> ScenarioRunner.Outcome
    ) async -> Bool {
        var allPassed = true
        for scenario in scenarios {
            for model in modelsFor(scenario) {
                print("\n── \(scenario.id) via \(displayName)/\(model) ──")
                do {
                    let outcome = try await runOne(scenario, model)
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
                    let message = "  ERROR \(displayName)/\(model) — backend did not produce a run: \(error)\n"
                    // Drain buffered stdout before the unbuffered stderr write:
                    // when both fds are merged into one file (`> log 2>&1`) the
                    // stderr bytes otherwise jump ahead of print() output still
                    // sitting in the stdio buffer, tearing lines mid-word.
                    fflush(stdout)
                    FileHandle.standardError.write(Data(message.utf8))
                }
            }
        }
        return allPassed
    }

    /// Prints the shared closing summary line and returns the process exit
    /// code (0 pass, 1 fail) — the exit-code policy every hand-rolled CLI
    /// main duplicated (`0` all scenarios passed, `1` at least one failure or
    /// infra error, `2` reserved by callers for bad arguments before this
    /// point is ever reached).
    public static func finish(allPassed: Bool, transcriptPath: URL) -> Int32 {
        if allPassed {
            print("\nAll scenarios passed.")
            return 0
        } else {
            print("\nOne or more scenarios failed — see \(transcriptPath.path)")
            return 1
        }
    }

    // MARK: - Tool-selection summary

    /// Prints the macro-averaged tool-selection `SUMMARY` line the decoy-
    /// pressure sweeps (`--extra-tools N`) grep for. Format is stable and
    /// greppable: fixed 3-decimal metric formatting, one line, no other
    /// output on the line.
    public static func printToolSelectionSummary(
        extraTools: Int,
        passedCount: Int,
        total: Int,
        cleanCount: Int,
        perScenarioCounts: [ConfusionCounts],
        decoyCallTotal: Int
    ) {
        let macro = MacroAveragedMetrics(perClass: perScenarioCounts)
        let line = "SUMMARY extra_tools=\(extraTools) passed=\(passedCount)/\(total) clean=\(cleanCount)/\(total) "
            + "precision=\(fmt3(macro.precision)) recall=\(fmt3(macro.recall)) f1=\(fmt3(macro.f1)) "
            + "decoy_calls=\(decoyCallTotal) scored=\(perScenarioCounts.count)"
        print(line)
    }

    /// Fixed 3-decimal formatting so `SUMMARY` metric values are stable and
    /// greppable (e.g. `f1=0.900`, never `f1=0.9`).
    private static func fmt3(_ value: Double) -> String { String(format: "%.3f", value) }
}
