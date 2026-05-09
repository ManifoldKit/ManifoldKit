import Foundation

public actor TerminalReporter {

    private let quiet: Bool
    private var currentIteration: IterationState?

    private struct IterationState {
        let iter: Int
        let model: String
        let temp: Float
        let totalFindings: Int
        let start: ContinuousClock.Instant
        let heartbeat: Task<Void, Never>
    }

    public init(quiet: Bool) {
        self.quiet = quiet
    }

    public func preflight(backend: String, model: String, detectors: [String]) {
        guard !quiet else { return }
        print("─── fuzz-chat preflight ───")
        print("  backend:   \(backend)")
        print("  model:     \(model)")
        print("  detectors: \(detectors.joined(separator: ", "))")
        print("───────────────────────────")
    }

    /// Prints the iteration banner and starts a 3s heartbeat that re-renders the
    /// status line with elapsed seconds, so the user can tell long generations
    /// (qwen3.5:4b can take 90s+) from a hung process.
    public func iterationStart(iter: Int, model: String, temp: Float, totalFindings: Int) {
        // Cancel any previous heartbeat that wasn't ended (defensive).
        currentIteration?.heartbeat.cancel()

        let start = ContinuousClock.now
        if !quiet {
            renderStatus(iter: iter, model: model, temp: temp, totalFindings: totalFindings, elapsedSeconds: 0)
        }

        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return  // cancellation is the only expected exit
                }
                await self?.tickHeartbeat()
            }
        }
        currentIteration = IterationState(
            iter: iter,
            model: model,
            temp: temp,
            totalFindings: totalFindings,
            start: start,
            heartbeat: heartbeat
        )
    }

    /// Cancels the running heartbeat. Safe to call when no iteration is active.
    public func iterationEnd() {
        currentIteration?.heartbeat.cancel()
        currentIteration = nil
    }

    private func tickHeartbeat() {
        guard !quiet, let state = currentIteration else { return }
        let elapsed = Int(state.start.duration(to: ContinuousClock.now).components.seconds)
        renderStatus(iter: state.iter, model: state.model, temp: state.temp, totalFindings: state.totalFindings, elapsedSeconds: elapsed)
    }

    private func renderStatus(iter: Int, model: String, temp: Float, totalFindings: Int, elapsedSeconds: Int) {
        let line: String
        if elapsedSeconds <= 0 {
            line = String(format: "[iter %d] %@ temp=%.1f findings=%d", iter, model, temp, totalFindings)
        } else {
            line = String(format: "[iter %d] %@ temp=%.1f findings=%d elapsed=%ds", iter, model, temp, totalFindings, elapsedSeconds)
        }
        FileHandle.standardOutput.write(Data("\r\u{1B}[K\(line)".utf8))
    }

    public func finding(_ f: Finding) {
        // Always print finding events, even in quiet mode
        let trigger = f.trigger.replacingOccurrences(of: "\n", with: " ").prefix(80)
        print("\n  ↑ \(f.severity.rawValue) [\(f.detectorId)/\(f.subCheck)] hash=\(f.hash) :: \(trigger)")
    }

    public func error(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }

    public func finalSummary(report: FuzzReport) {
        guard !quiet else { return }
        let perDetectorLines = report.perDetectorFlagRate
            .sorted { $0.value > $1.value }
            .map { String(format: "    %@   %.2f%% flag rate", $0.key, $0.value * 100) }
            .joined(separator: "\n")
        print("\n━━━ FUZZ SUMMARY ━━━")
        print("  Iterations:      \(report.totalRuns)")
        print("  Unique findings: \(report.dedupedCount)")
        if !perDetectorLines.isEmpty {
            print("  Detectors:")
            print(perDetectorLines)
        }
        print("  Triage:          open tmp/fuzz/INDEX.md")
        print("━━━━━━━━━━━━━━━━━━━━")
    }
}
