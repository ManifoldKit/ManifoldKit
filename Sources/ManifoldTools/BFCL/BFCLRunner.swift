import Foundation
import ManifoldInference

/// Backend-agnostic driver for the BFCL argument-level evaluation.
///
/// The per-case loop — render tools into the prompt via the production path,
/// capture the model's first tool call, score it at the argument level with
/// ``ASTMatcher``, and contrast against the name-only check — is identical across
/// backends. Only the construction of the ``InferenceService`` differs (Ollama in
/// core `manifold-tools`; `LlamaBackend` / MLX in the companion CLIs). Lifting the
/// loop here lets every backend share one scorer and one output format.
@MainActor
public struct BFCLRunner {

    /// Aggregate counts for one model's run.
    public struct Summary: Equatable, Sendable {
        public let total: Int
        public let astMatched: Int
        public let nameMatched: Int
        public let errored: Int
    }

    /// Per-case capture records plus the aggregate summary.
    public struct Outcome: Sendable {
        public let records: [BFCLRunRecord]
        public let summary: Summary
    }

    /// Where human-readable progress rows go. Defaults to stdout; tests inject a
    /// capturing sink.
    private let log: (String) -> Void

    public init(log: @escaping (String) -> Void = { print($0) }) {
        self.log = log
    }

    /// Runs every case through a configured ``InferenceService`` (any backend).
    ///
    /// - Parameters:
    ///   - cases: the loaded BFCL cases to score.
    ///   - service: a backend-loaded inference service. Its tool registry should
    ///     be empty — we capture the model's first call and score it, never
    ///     dispatch it.
    ///   - modelLabel: e.g. `"ollama/llama3.1-8b"`, used in the header and dump.
    ///   - perCaseTimeoutSeconds: per-case generation deadline. A case that
    ///     exceeds it is cancelled at the backend and counted as errored — so one
    ///     non-terminating generation (a model that never emits a stop token, seen
    ///     on MLX) can't stall the whole run. Carries over to every backend that
    ///     drives the runner (Ollama / Llama / MLX).
    public func run(
        cases: [BFCLLoadedCase],
        service: InferenceService,
        modelLabel: String,
        perCaseTimeoutSeconds: Double = 120
    ) async -> Outcome {
        await run(cases: cases, modelLabel: modelLabel) { testCase in
            try await Self.emittedCalls(for: testCase, service: service, timeoutSeconds: perCaseTimeoutSeconds)
        }
    }

    /// Backend-free core of the loop: scores whatever `emit` produces per case.
    /// The `emit` seam keeps the orchestration (scoring, records, output format)
    /// unit-testable without a live model.
    public func run(
        cases: [BFCLLoadedCase],
        modelLabel: String,
        emit: (BFCLLoadedCase) async throws -> [ToolCall]
    ) async -> Outcome {
        log("\nBFCL — \(modelLabel)  (\(cases.count) cases)")

        var astMatched = 0
        var nameMatched = 0
        var errored = 0
        var records: [BFCLRunRecord] = []

        // The AST and name-only checks are real `EvalScorer`s over the emitted
        // calls; the runner accounts for the run through their `Score` output.
        let astScorer = BFCLASTScorer()
        let nameScorer = BFCLNameOnlyScorer()

        for testCase in cases {
            let id = testCase.id.padding(toLength: 13, withPad: " ", startingAt: 0)

            // A single case erroring (e.g. a backend 500 on malformed tool output)
            // must not abort the whole run — count it and continue.
            let calls: [ToolCall]
            do {
                calls = try await emit(testCase)
            } catch {
                errored += 1
                log("  ⚠ \(id) <error: \(Self.shortError(error))>")
                continue
            }

            // A BFCL case is a tool-call eval: the projected output carries the
            // emitted calls; visible/thinking text is legitimately empty here.
            let output = EvalRunOutput(visibleText: "", toolCalls: calls)
            let astScore = await astScorer.score(output: output, expected: testCase.groundTruth)
            let nameScore = await nameScorer.score(output: output, expected: testCase.groundTruth)
            let astOK = astScore.value == .bool(true)
            let nameOK = nameScore.value == .bool(true)
            if astOK { astMatched += 1 }
            if nameOK { nameMatched += 1 }
            records.append(BFCLRunRecord.make(
                id: testCase.id,
                model: modelLabel,
                emittedCalls: calls,
                astMatched: astOK,
                nameMatched: nameOK
            ))

            let marker = astOK ? "✓" : "✗"
            let emitted = calls.first.map { "\($0.toolName) \($0.arguments)" } ?? "<no tool call>"
            var line = "  \(marker) \(id) \(emitted)"
            if !astOK, let reason = astScore.explanation {
                // Name matched but arguments wrong → exactly the gap the name-only
                // scorer misses. Surface why.
                line += "   ↳ \(reason)"
            }
            log(line)
        }

        let total = cases.count
        log("  ───")
        log("  AST accuracy (right function + right arguments): \(astMatched)/\(total) (\(Self.pct(astMatched, total)))")
        log("  Name-only (what ConformanceScorer credits):      \(nameMatched)/\(total) (\(Self.pct(nameMatched, total)))")
        let gap = nameMatched - astMatched
        if gap > 0 {
            log("  → \(gap) case(s) called the right tool with WRONG arguments — invisible to the name-only scorer.")
        }
        if errored > 0 {
            log("  (\(errored) case(s) errored at the backend and were not scored.)")
        }

        return Outcome(
            records: records,
            summary: Summary(total: total, astMatched: astMatched, nameMatched: nameMatched, errored: errored)
        )
    }

    /// Drives one case through the production tool-injection path and returns the
    /// tool calls the model emitted on its first turn.
    ///
    /// Single-turn by design: an empty registry plus `maxToolIterations: 1` means
    /// we observe the model's first call and score it — we never execute the tool
    /// (the non-executable BFCL AST track has no execution semantics).
    public static func emittedCalls(
        for testCase: BFCLLoadedCase,
        service: InferenceService,
        timeoutSeconds: Double
    ) async throws -> [ToolCall] {
        let messages = [StructuredMessage(role: "user", content: testCase.prompt)]
        let config = GenerationConfig(
            temperature: 0.0,
            topP: 0.9,
            repeatPenalty: 1.1,
            topK: 1,
            maxOutputTokens: 512,
            tools: testCase.tools,
            toolChoice: .auto,
            maxThinkingTokens: nil,
            jsonMode: false,
            thinkingMarkers: nil,
            maxToolIterations: 1
        )
        let (token, stream) = try service.enqueue(structuredMessages: messages, systemPrompt: "", config: config)

        // Race the drain against the deadline. On timeout we MUST cancel the
        // backend generation (not just stop consuming): a model that never emits a
        // stop token would otherwise grind to maxOutputTokens and block the next
        // case — and cancelling the backend is what lets the drain task unblock.
        return try await withCaseTimeout(
            seconds: timeoutSeconds,
            cancel: { service.cancel(token) },
            drain: {
                var calls: [ToolCall] = []
                for try await event in stream.events {
                    if case .toolCall(let call) = event { calls.append(call) }
                }
                return calls
            }
        )
    }

    /// Thrown when one case's generation exceeds the per-case timeout. The run
    /// loop counts it as an errored case and continues, like a backend error.
    public struct CaseTimeout: Error, CustomStringConvertible {
        public let seconds: Double
        public var description: String { "generation timed out after \(Int(seconds))s" }
    }

    /// Races a stream-drain against a deadline. On timeout, calls `cancel` — which
    /// must halt the backend so the drain unblocks — and throws ``CaseTimeout``.
    /// Extracted so the race/cancel logic is testable without a live model.
    static func withCaseTimeout(
        seconds: Double,
        cancel: () -> Void,
        drain: @escaping @Sendable () async throws -> [ToolCall]
    ) async throws -> [ToolCall] {
        try await withThrowingTaskGroup(of: [ToolCall].self) { group in
            group.addTask { try await drain() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CaseTimeout(seconds: seconds)
            }
            defer { group.cancelAll() }
            do {
                // First task to finish wins: drain success returns calls; the
                // sleep task throws CaseTimeout; a drain error rethrows here.
                // `next()` is nil only with no child tasks — unreachable (two were
                // added), so an empty result degrades safely to "no tool call".
                guard let calls = try await group.next() else { return [] }
                return calls
            } catch {
                cancel()
                throw error
            }
        }
    }

    /// Trims a backend error to a single readable line for the per-case row.
    static func shortError(_ error: Error) -> String {
        let full = "\(error)"
        return full.count > 120 ? String(full.prefix(120)) + "…" : full
    }

    static func pct(_ n: Int, _ d: Int) -> String {
        guard d > 0 else { return "—" }
        return String(format: "%.1f%%", Double(n) / Double(d) * 100)
    }
}
