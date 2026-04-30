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
        var workers = 1
        var outputDir = URL(fileURLWithPath: "tmp/fuzz", isDirectory: true)

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
            case "--workers":
                i = argv.index(after: i)
                guard i < argv.endIndex, let n = Int(argv[i]), n > 0 else { fail("--workers requires a positive integer") }
                workers = n
            case "--output-dir":
                i = argv.index(after: i)
                guard i < argv.endIndex else { fail("--output-dir requires a path") }
                outputDir = URL(fileURLWithPath: argv[i], isDirectory: true)
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

        // Default termination if neither flag passed: 5 minutes.
        if minutes == nil && iterations == nil && replayHash == nil && shrinkHash == nil { minutes = 5 }

        if workers > 1 {
            if replayHash != nil || shrinkHash != nil {
                fail("--workers is only supported for fuzz campaigns, not --replay or --shrink")
            }
            do {
                let slices = try ParallelFuzzWorkerPlanner.makePlan(
                    backend: backend,
                    requestedWorkers: workers,
                    seed: seed,
                    minutes: minutes,
                    iterations: iterations
                )
                let status = runParallelCampaign(
                    options: CampaignOptions(
                        backend: backend,
                        minutes: minutes,
                        iterations: iterations,
                        seed: seed,
                        modelHint: modelHint,
                        detectorFilter: detectorFilter,
                        quiet: quiet,
                        sessionScripts: sessionScripts,
                        corpusSubset: corpusSubset,
                        tools: tools,
                        outputDir: outputDir
                    ),
                    slices: slices
                )
                exit(status)
            } catch ParallelFuzzWorkerPlanError.backendWorkerLimit(let backend, let requested, let limit) {
                fail("--workers \(requested) is not safe for backend \(backend.rawValue); maximum is \(limit)")
            } catch ParallelFuzzWorkerPlanError.invalidWorkerCount(let count) {
                fail("--workers requires a positive integer (got \(count))")
            } catch {
                fail("parallel worker planning failed: \(error)")
            }
        }

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
            tools: tools,
            workers: workers
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

    struct CampaignOptions {
        var backend: BackendChoice
        var minutes: Int?
        var iterations: Int?
        var seed: UInt64
        var modelHint: String?
        var detectorFilter: Set<String>?
        var quiet: Bool
        var sessionScripts: Bool
        var corpusSubset: Corpus.Subset
        var tools: Bool
        var outputDir: URL
    }

    struct WorkerProcess {
        var process: Process
        var logHandle: FileHandle
        var outputDir: URL
        var logURL: URL
    }

    static func runParallelCampaign(options: CampaignOptions, slices: [ParallelFuzzWorkerSlice]) -> Int32 {
        let runId = UUID().uuidString
        let workersRoot = options.outputDir
            .appendingPathComponent("workers", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: workersRoot, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("fuzz-chat: failed to create worker directory: \(error)\n".utf8))
            return 3
        }

        if !options.quiet {
            print("Starting \(slices.count) fuzz workers; logs: \(workersRoot.path)")
        }

        var workers: [WorkerProcess] = []
        for slice in slices {
            let workerDir = workersRoot.appendingPathComponent("worker-\(slice.index)", isDirectory: true)
            let workerOutputDir = workerDir.appendingPathComponent("fuzz", isDirectory: true)
            let logURL = workerDir.appendingPathComponent("worker.log")
            do {
                try fm.createDirectory(at: workerOutputDir, withIntermediateDirectories: true)
                fm.createFile(atPath: logURL.path, contents: nil)
                let logHandle = try FileHandle(forWritingTo: logURL)

                let process = Process()
                process.executableURL = executableURL
                process.arguments = workerArguments(options: options, slice: slice, outputDir: workerOutputDir)
                process.standardOutput = logHandle
                process.standardError = logHandle
                try process.run()
                workers.append(WorkerProcess(process: process, logHandle: logHandle, outputDir: workerOutputDir, logURL: logURL))
            } catch {
                FileHandle.standardError.write(Data("fuzz-chat: failed to start worker \(slice.index): \(error)\n".utf8))
                for worker in workers {
                    worker.process.terminate()
                    worker.logHandle.closeFile()
                }
                return 3
            }
        }

        var failedWorkers: [(Int32, URL)] = []
        for worker in workers {
            worker.process.waitUntilExit()
            worker.logHandle.closeFile()
            if worker.process.terminationStatus != 0 {
                failedWorkers.append((worker.process.terminationStatus, worker.logURL))
            }
        }

        do {
            let mergeInputs = [options.outputDir] + workers.map(\.outputDir)
            let report = try FindingsMerger.merge(workerOutputDirs: mergeInputs, into: options.outputDir)
            if !options.quiet {
                var message = "Merged \(report.totalRuns) total runs and \(report.uniqueFindings) unique findings into \(options.outputDir.path)"
                if report.skippedInputs > 0 {
                    message += " (\(report.skippedInputs) input(s) skipped due to unreadable index.json)"
                }
                print(message)
            }
        } catch {
            FileHandle.standardError.write(Data("fuzz-chat: failed to merge worker findings: \(error)\n".utf8))
            return 3
        }

        if !failedWorkers.isEmpty {
            for (status, logURL) in failedWorkers {
                FileHandle.standardError.write(Data("fuzz-chat: worker exited \(status); see \(logURL.path)\n".utf8))
            }
            return 1
        }
        return 0
    }

    static func workerArguments(options: CampaignOptions, slice: ParallelFuzzWorkerSlice, outputDir: URL) -> [String] {
        var args: [String] = [
            "--backend", options.backend.rawValue,
            "--seed", "\(slice.seed)",
            "--output-dir", outputDir.path,
            "--corpus-subset", options.corpusSubset.rawValue,
        ]
        if let iterations = slice.iterations {
            args += ["--iterations", "\(iterations)"]
        }
        if let minutes = slice.minutes {
            args += ["--minutes", "\(minutes)"]
        }
        if let modelHint = options.modelHint {
            args += ["--model", modelHint]
        }
        if let detectorFilter = options.detectorFilter, !detectorFilter.isEmpty {
            args += ["--detector", detectorFilter.sorted().joined(separator: ",")]
        }
        if options.quiet {
            args.append("--quiet")
        }
        if options.sessionScripts {
            args.append("--session-scripts")
        }
        if options.tools {
            args.append("--tools")
        }
        return args
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
            "  --workers N         process-level workers for campaign mode (default 1).",
            "                      Iterations are split; time budgets apply per worker.",
            "  --output-dir PATH   findings directory (default tmp/fuzz)",
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
