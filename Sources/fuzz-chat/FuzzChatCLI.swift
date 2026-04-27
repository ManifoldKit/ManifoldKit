import Foundation
import BaseChatFuzz
import BaseChatInference
#if Fuzz
import BaseChatFuzzBackends
#endif

@main
@MainActor
struct FuzzChatCLI {

    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst().filter { $0 != "--" })

        if argv.contains("--help") || argv.contains("-h") {
            printUsage()
            return
        }

        var backend: BackendChoice = .ollama
        var minutes: Int?
        var iterations: Int?
        var seed: UInt64 = UInt64.random(in: 0...UInt64.max)
        var modelHint: String?
        var detectorFilter: Set<String>?
        var quiet = false
        var replayHash: String?
        var shrinkHash: String?
        var force = false
        var sessionScripts = false
        var corpusSubset: Corpus.Subset = .full
        var tools = false

        var i = argv.startIndex
        while i < argv.endIndex {
            let arg = argv[i]
            switch arg {
            case "--backend":
                i = argv.index(after: i)
                guard i < argv.endIndex, let b = BackendChoice(rawValue: argv[i]) else {
                    fail("--backend requires one of: \(BackendChoice.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                backend = b
            case "--minutes":
                i = argv.index(after: i)
                guard i < argv.endIndex, let n = Int(argv[i]) else { fail("--minutes requires an integer") }
                minutes = n
            case "--iterations":
                i = argv.index(after: i)
                guard i < argv.endIndex, let n = Int(argv[i]) else { fail("--iterations requires an integer") }
                iterations = n
            case "--seed":
                i = argv.index(after: i)
                guard i < argv.endIndex, let n = UInt64(argv[i]) else { fail("--seed requires a UInt64") }
                seed = n
            case "--model":
                i = argv.index(after: i)
                guard i < argv.endIndex else { fail("--model requires a value") }
                modelHint = argv[i]
            case "--detector":
                i = argv.index(after: i)
                guard i < argv.endIndex else { fail("--detector requires a value") }
                detectorFilter = Set(argv[i].split(separator: ",").map(String.init))
            case "--quiet":
                quiet = true
            case "--single":
                iterations = 1
            case "--replay":
                i = argv.index(after: i)
                guard i < argv.endIndex else { fail("--replay requires a hash value") }
                let candidate = argv[i]
                guard isValidReplayHash(candidate) else {
                    fail("--replay hash must be 12–40 lowercase hex characters (got: \(candidate))")
                }
                replayHash = candidate
            case "--shrink":
                i = argv.index(after: i)
                guard i < argv.endIndex else { fail("--shrink requires a hash value") }
                let candidate = argv[i]
                guard isValidReplayHash(candidate) else {
                    fail("--shrink hash must be 12–40 lowercase hex characters (got: \(candidate))")
                }
                shrinkHash = candidate
            case "--force":
                force = true
            case "--session-scripts":
                sessionScripts = true
            case "--tools":
                tools = true
            case "--corpus-subset":
                i = argv.index(after: i)
                guard i < argv.endIndex else { fail("--corpus-subset requires a value (full|smoke)") }
                guard let subset = Corpus.Subset(rawValue: argv[i]) else {
                    fail("--corpus-subset must be one of: full, smoke")
                }
                corpusSubset = subset
            default:
                fail("unknown argument: \(arg)")
            }
            i = argv.index(after: i)
        }

        if backend == .mlx {
            fail("MLX cannot run via `swift run` (needs Xcode-compiled metallib). Use scripts/fuzz.sh or xcodebuild.")
        }

        let outputDir = URL(fileURLWithPath: "tmp/fuzz", isDirectory: true)

        let factory: any FuzzBackendFactory
        switch backend {
        case .ollama:
            #if Fuzz && Ollama
            do {
                factory = try OllamaFuzzFactory.makeCampaignFactory(modelHint: modelHint)
            } catch {
                fail(String(describing: error))
            }
            #else
            fail("Ollama backend requires the Fuzz and Ollama build traits. Run via: scripts/fuzz.sh")
            #endif
        case .mock:
            factory = MockFuzzFactory()
        case .chaos:
            factory = ChaosFuzzFactory()
        case .llama:
            #if Llama && Fuzz
            factory = LlamaFuzzFactory(modelHint: modelHint)
            #else
            fail("Llama backend requires the Fuzz and Llama build traits. Run via: scripts/fuzz.sh")
            #endif
        case .foundation:
            #if canImport(FoundationModels) && Fuzz
            if #available(macOS 26, iOS 26, *) {
                factory = FoundationFuzzFactory()
            } else {
                fail("Foundation backend requires macOS 26 or iOS 26.")
            }
            #else
            fail("Foundation backend requires macOS 26+ with FoundationModels and the Fuzz build trait. Run via: scripts/fuzz.sh")
            #endif
        case .mlx:
            fail("MLX cannot run via `swift run` (needs Xcode-compiled metallib). Use scripts/fuzz.sh --with-mlx or --backend mlx.")
        case .all:
            fail("all backend not yet wired in CLI.")
        }

        // Shrink mode: greedy-delta-debug the recorded trigger down to a
        // minimal still-reproducing input. Implies replay — we reuse the
        // `Replayer` under the hood — so `--shrink` is exclusive with
        // `--replay`. See Sources/BaseChatFuzz/Replay/Shrinker.swift.
        if let hash = shrinkHash {
            if replayHash != nil {
                fail("--shrink and --replay cannot be combined (shrink already replays)")
            }
            let exitCode = await runShrink(
                hash: hash,
                outputDir: outputDir,
                factory: factory
            )
            await factory.teardown()
            exit(exitCode)
        }

        // Replay mode short-circuits the campaign loop entirely. It reruns a
        // single recorded finding against the same prompt/config/seed 3x and
        // prints a promotion verdict. See Sources/BaseChatFuzz/Replay/Replayer.swift.
        if let hash = replayHash {
            let exitCode = await runReplay(
                hash: hash,
                force: force,
                outputDir: outputDir,
                factory: factory
            )
            await factory.teardown()
            exit(exitCode)
        }

        // Default termination if neither flag passed: 5 minutes.
        if minutes == nil && iterations == nil { minutes = 5 }

        let config = FuzzConfig(
            backend: backend,
            minutes: minutes,
            iterations: iterations,
            seed: seed,
            modelHint: modelHint,
            detectorFilter: detectorFilter,
            outputDir: outputDir,
            calibrate: false,
            quiet: quiet,
            sessionScripts: sessionScripts,
            corpusSubset: corpusSubset,
            tools: tools
        )

        let reporter = TerminalReporter(quiet: quiet)
        if sessionScripts {
            let runner = SessionFuzzRunner(config: config, factory: factory)
            _ = await runner.run(reporter: reporter)
        } else {
            let runner = FuzzRunner(config: config, factory: factory)
            _ = await runner.run(reporter: reporter)
        }
        // Ordered backend teardown before process exit. The default implementation
        // is a no-op; LlamaFuzzFactory overrides this to await unloadAndWait(),
        // preventing the SIGABRT from ggml-metal resource-set teardown (#391).
        await factory.teardown()
    }

    /// Drives the Replayer and maps its `Outcome` to an exit code + summary line.
    /// Exit codes match the issue brief:
    ///   0  — reproduced or not-reproduced (both are valid data)
    ///   2  — record not found, drift refused, schema unsupported, non-deterministic
    ///   3  — internal error (decode failure, factory failure)
    static func runReplay(
        hash: String,
        force: Bool,
        outputDir: URL,
        factory: any FuzzBackendFactory
    ) async -> Int32 {
        let replayer = Replayer(findingsRoot: outputDir, factory: factory)
        let outcome: Replayer.Outcome
        do {
            outcome = try await replayer.replay(hash: hash, attempts: 3, force: force)
        } catch {
            FileHandle.standardError.write(Data("Replay \(hash): failed — \(error)\n".utf8))
            return 3
        }

        switch outcome {
        case .reproduced(let result):
            let verdict: String = {
                if result.newSeverity == .confirmed {
                    return "promoted to confirmed"
                } else {
                    return "remains flaky"
                }
            }()
            var line = "Replay \(hash): reproduced \(result.successfulReproductions)/\(result.attempts) — \(verdict)"
            if result.drift != nil {
                line += " [forced despite drift]"
            }
            print(line)
            return 0

        case .driftRefused(let report):
            var parts: [String] = []
            if report.gitDrifted {
                parts.append("git \(report.recordedGitRev) → \(report.currentGitRev)")
            }
            if report.modelHashDrifted {
                let a = report.recordedModelHash?.prefix(12) ?? "nil"
                let b = report.currentModelHash?.prefix(12) ?? "nil"
                parts.append("model \(a) → \(b)")
            }
            let explanation = parts.joined(separator: "; ")
            print("Replay \(hash): drift refused (\(explanation)); pass --force to override")
            return 2

        case .recordNotFound:
            print("Replay \(hash): record not found")
            return 2

        case .schemaUnsupported(let v):
            print("Replay \(hash): schema version \(v) is newer than harness (supported: \(RunRecord.currentSchema))")
            return 2

        case .nonDeterministicBackend(let name):
            print("Replay \(hash): non-deterministic backend (\(name)); --replay not supported")
            return 2
        }
    }

    /// Drives the Shrinker and maps its `Result` / errors to an exit code +
    /// summary line. Exit codes:
    ///   0  — successful shrink (either reached minimal or exhausted budget)
    ///   2  — non-determinism or no-reproduction pre-check failed
    ///   3  — internal error (record-not-found, replay failure)
    static func runShrink(
        hash: String,
        outputDir: URL,
        factory: any FuzzBackendFactory
    ) async -> Int32 {
        let replayer = Replayer(findingsRoot: outputDir, factory: factory)
        let shrinker = Shrinker(replayer: replayer)

        let result: Shrinker.Result
        do {
            result = try await shrinker.shrink(hash: hash)
        } catch Shrinker.Failure.recordNotFound(let h) {
            FileHandle.standardError.write(Data("Shrink \(h): record not found\n".utf8))
            return 3
        } catch {
            FileHandle.standardError.write(Data("Shrink \(hash): internal error — \(error)\n".utf8))
            return 3
        }

        switch result.reason {
        case .minimal:
            print("Shrink \(hash): shrunk \(result.originalPromptLength) chars → \(result.shrunkPromptLength) chars in \(result.steps) steps (minimal)")
            persistShrunkArtefact(shrinker: shrinker, hash: hash, result: result)
            return 0
        case .budgetExhausted:
            print("Shrink \(hash): shrunk \(result.originalPromptLength) chars → \(result.shrunkPromptLength) chars in \(result.steps) steps (budget exhausted)")
            persistShrunkArtefact(shrinker: shrinker, hash: hash, result: result)
            return 0
        case .nonDeterministic:
            print("Shrink \(hash): input is flaky, not shrinkable")
            return 2
        case .noReproduction:
            print("Shrink \(hash): original input does not reproduce (0/3); nothing to shrink")
            return 2
        }
    }

    /// Best-effort persistence of `shrunk.json`. A write failure is reported
    /// on stderr but does NOT downgrade the exit code — the shrinker's result
    /// is the source of truth, and the CLI already printed the summary line.
    static func persistShrunkArtefact(shrinker: Shrinker, hash: String, result: Shrinker.Result) {
        do {
            _ = try shrinker.writeShrunkArtefact(hash: hash, result: result)
        } catch {
            FileHandle.standardError.write(Data("Shrink \(hash): warning — could not write shrunk.json: \(error)\n".utf8))
        }
    }

    /// Validates `--replay` argument shape: 12–40 lowercase hex chars. Finding
    /// hashes produced by `Finding.computeHash` are exactly 12 chars today;
    /// allowing up to 40 lets us roundtrip full SHA-256 prefixes if the finding
    /// hash length ever grows without a CLI change.
    static func isValidReplayHash(_ s: String) -> Bool {
        guard (12...40).contains(s.count) else { return false }
        return s.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    static func printUsage() {
        let lines = [
            "fuzz-chat — chat anomaly fuzzer",
            "",
            "Usage: swift run --traits Fuzz,MLX,Llama,Ollama fuzz-chat [options]",
            "",
            "Options:",
            "  --backend ollama|mock|chaos|llama|foundation|mlx|all   default: ollama",
            "                      mock  = MockInferenceBackend (hardware-free, used by PR-tier CI)",
            "                      chaos = ChaosBackend (hardware-free; injects stream failures)",
            "  --minutes N         time budget (default 5 if neither flag set)",
            "  --iterations N      iteration budget",
            "  --seed N            RNG seed (default random)",
            "  --model <substr>    Ollama: pin to first installed model containing <substr>.",
            "                      Pass `all` (or omit) to rotate through every installed",
            "                      Ollama model, one per iteration. Llama: pin to the",
            "                      first GGUF whose filename contains <substr>; `all` is",
            "                      ignored because llama.cpp stays single-model.",
            "  --detector ids      comma-separated detector ids to run",
            "  --single            shorthand for --iterations 1",
            "  --quiet             suppress live output (still prints findings)",
            "  --replay <hash>     rerun a recorded finding (12–40 hex chars)",
            "  --shrink <hash>     greedy delta-debug a finding down to a minimal repro",
            "                      (implies --replay; exclusive with it)",
            "  --force             ignore git/model drift on --replay",
            "  --session-scripts   drive bundled multi-turn SessionScripts via",
            "                      InferenceService.enqueue (opt-in for this PR;",
            "                      exercises queue, cancellation, session scoping).",
            "  --tools             inject `SyntheticToolset` so tool-aware backends",
            "                      have something to call. Pairs with the",
            "                      tool-call-validity detector (#627).",
            "  --corpus-subset full|smoke  default: full.",
            "                      `smoke` loads the small deterministic seed set",
            "                      used by the PR-tier CI fuzz job.",
            "  -h, --help          this help",
        ]
        print(lines.joined(separator: "\n"))
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fuzz-chat: \(message)\n".utf8))
    exit(2)
}
