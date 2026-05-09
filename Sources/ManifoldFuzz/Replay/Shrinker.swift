import Foundation
import ManifoldInference

/// Greedy delta-debugger for fuzz findings.
///
/// When a fuzz finding lands, the trigger prompt is whatever the corpus +
/// mutator chain produced — often long, with multiple layered mutations. This
/// struct reduces the recorded input to a minimal still-failing repro so
/// triaging a finding doesn't require manually guessing "is this still a bug
/// if I drop the unicode injection?".
///
/// Layered atop `Replayer`: the loaded record and its per-attempt reproduce
/// count come from there, and the reproduction gate is the same (detector
/// emitted a Finding with the original hash). The shrinker wraps that in a
/// bounded search:
///
/// 1. **Pre-check.** Replay 3× at the original record. Refuse flaky inputs
///    (<2/3) rather than bisect against noise.
/// 2. **Drop mutators** one-at-a-time. Commit each removal that still
///    reproduces.
/// 3. **Drop system prompt** once, if present.
/// 4. **Halve `maxTokens`** until halving no longer reproduces.
/// 5. **Bisect prompt messages** — try the first half, then the second,
///    recursing until no split shrinks further.
/// 6. **Monotonicity post-check.** Re-run 3× on the final candidate; if
///    reproduction drops below 2/3 revert to the previous committed state.
///
/// Bounded by `maxSteps` (default 20) or `timeLimit` seconds (default 300) —
/// whichever hits first.
public struct Shrinker: Sendable {

    public struct Result: Sendable {
        public let originalPromptLength: Int
        public let shrunkPromptLength: Int
        public let shrunkPrompt: String
        public let shrunkSystemPrompt: String?
        public let shrunkMutators: [String]
        public let steps: Int
        public let reason: TerminationReason
    }

    public enum TerminationReason: String, Sendable {
        /// A full pass found no further reduction that still reproduces.
        case minimal
        /// `maxSteps` or `timeLimit` hit before reaching minimal.
        case budgetExhausted
        /// Pre-check reproduce rate < 2/3 — refusing to shrink noise.
        case nonDeterministic
        /// Pre-check reproduce rate 0/3 — original record doesn't reproduce
        /// under the current backend/model at all, so there's nothing to shrink.
        case noReproduction
    }

    public enum Failure: Error, Sendable {
        case recordNotFound(String)
        case replayFailed(String)
    }

    private let replayer: Replayer
    private let clock: @Sendable () -> Date

    public init(replayer: Replayer, clock: (@Sendable () -> Date)? = nil) {
        self.replayer = replayer
        self.clock = clock ?? { Date() }
    }

    /// Greedy delta-debug the record identified by `hash` down to a minimal
    /// still-reproducing input. `maxSteps` caps the total number of
    /// reduction-attempts (every tryCandidate call, whether committed or
    /// rejected); `timeLimit` is a wall-clock budget in seconds.
    @MainActor
    public func shrink(
        hash: String,
        maxSteps: Int = 20,
        timeLimit: TimeInterval = 300
    ) async throws -> Result {
        guard let seed = try replayer.loadRecord(hash: hash) else {
            throw Failure.recordNotFound(hash)
        }

        let originalJoined = joinedPrompt(seed.prompt.messages)

        // 1. Pre-check non-determinism.
        let precheckHits: Int
        do {
            precheckHits = try await replayer.replay(record: seed, originalHash: hash, attempts: 3)
        } catch {
            throw Failure.replayFailed(String(describing: error))
        }
        if precheckHits == 0 {
            return Result(
                originalPromptLength: originalJoined.count,
                shrunkPromptLength: originalJoined.count,
                shrunkPrompt: originalJoined,
                shrunkSystemPrompt: seed.config.systemPrompt,
                shrunkMutators: seed.prompt.mutators,
                steps: 0,
                reason: .noReproduction
            )
        }
        if precheckHits < 2 {
            return Result(
                originalPromptLength: originalJoined.count,
                shrunkPromptLength: originalJoined.count,
                shrunkPrompt: originalJoined,
                shrunkSystemPrompt: seed.config.systemPrompt,
                shrunkMutators: seed.prompt.mutators,
                steps: 0,
                reason: .nonDeterministic
            )
        }

        // Start of budgeted shrinking. `current` is the best-known still-repro
        // record; `previous` is retained for monotonicity revert (phase 6).
        var current = seed
        var previous = seed
        var steps = 0
        let deadline = clock().addingTimeInterval(timeLimit)
        var reason: TerminationReason = .minimal

        // Helper: returns true if we should keep going. Not @Sendable — the
        // whole `shrink` is @MainActor-bound and nested funcs would otherwise
        // trip Swift 6's actor-isolated-capture check on `steps`.
        func budgetOK() -> Bool {
            if steps >= maxSteps { return false }
            if clock() >= deadline { return false }
            return true
        }

        func tryReplace(_ candidate: RunRecord) async throws -> Bool {
            // Each candidate attempt costs one step whether or not it sticks.
            steps += 1
            let hits: Int
            do {
                hits = try await replayer.replay(record: candidate, originalHash: hash, attempts: 1)
            } catch {
                throw Failure.replayFailed(String(describing: error))
            }
            return hits >= 1
        }

        // Phase 1: drop mutators one-at-a-time. Iterating by index is OK
        // because we rebuild the list each commit; the loop restarts after
        // every successful drop so we pass over the smaller list again.
        var phase1Progress = true
        while phase1Progress && budgetOK() {
            phase1Progress = false
            let mutators = current.prompt.mutators
            for idx in mutators.indices {
                if !budgetOK() { reason = .budgetExhausted; break }
                var trimmed = mutators
                trimmed.remove(at: idx)
                let candidate = withMutators(trimmed, in: current)
                if try await tryReplace(candidate) {
                    previous = current
                    current = candidate
                    phase1Progress = true
                    break // restart the loop over the smaller list
                }
            }
        }

        // Phase 2: drop system prompt entirely.
        if budgetOK(), current.config.systemPrompt != nil {
            let candidate = withSystemPrompt(nil, in: current)
            if try await tryReplace(candidate) {
                previous = current
                current = candidate
            }
        }

        // Phase 3: halve maxTokens while it's > 32 and halving still reproduces.
        while budgetOK(), let t = current.config.maxTokens, t > 32 {
            let half = max(32, t / 2)
            if half == t { break }
            let candidate = withMaxTokens(half, in: current)
            if try await tryReplace(candidate) {
                previous = current
                current = candidate
            } else {
                break
            }
        }

        // Phase 4: prompt bisection. Work on the concatenated prompt text —
        // splitting preserves message boundaries by collapsing to a single
        // user message (delta-debug only cares about what text is still in
        // the prompt; message structure is reconstructable from context).
        var phase4Progress = true
        while phase4Progress && budgetOK() {
            phase4Progress = false
            let text = joinedPrompt(current.prompt.messages)
            if text.count <= 1 { break }

            let mid = text.index(text.startIndex, offsetBy: text.count / 2)
            let first = String(text[text.startIndex..<mid])
            let second = String(text[mid..<text.endIndex])

            // Try the first half.
            if !first.isEmpty, budgetOK() {
                let candidate = withPromptText(first, in: current)
                if try await tryReplace(candidate) {
                    previous = current
                    current = candidate
                    phase4Progress = true
                    continue
                }
            }
            // Fall through to second half.
            if !second.isEmpty, budgetOK() {
                let candidate = withPromptText(second, in: current)
                if try await tryReplace(candidate) {
                    previous = current
                    current = candidate
                    phase4Progress = true
                    continue
                }
            }
            // Neither half reproduced — stop bisecting.
        }

        if !budgetOK() && reason != .budgetExhausted {
            reason = .budgetExhausted
        }

        // Phase 5: monotonicity post-check. If the final state no longer
        // reproduces with quorum, revert to the previous committed state.
        let finalHits: Int
        do {
            finalHits = try await replayer.replay(record: current, originalHash: hash, attempts: 3)
        } catch {
            throw Failure.replayFailed(String(describing: error))
        }
        if finalHits < 2 {
            current = previous
        }

        let finalText = joinedPrompt(current.prompt.messages)
        return Result(
            originalPromptLength: originalJoined.count,
            shrunkPromptLength: finalText.count,
            shrunkPrompt: finalText,
            shrunkSystemPrompt: current.config.systemPrompt,
            shrunkMutators: current.prompt.mutators,
            steps: steps,
            reason: reason
        )
    }

    // MARK: - Persistence

    /// Writes `shrunk.json` next to `record.json` in the finding directory.
    /// Returns the URL it wrote (or nil if the finding directory isn't
    /// resolvable, which happens in ad-hoc unit tests that bypass the
    /// findings layout).
    public func writeShrunkArtefact(hash: String, result: Result) throws -> URL? {
        guard let dir = replayer.findingDirectory(forHash: hash) else { return nil }
        let payload: [String: Any] = [
            "originalPromptLength": result.originalPromptLength,
            "shrunkPromptLength": result.shrunkPromptLength,
            "shrunkPrompt": result.shrunkPrompt,
            "shrunkSystemPrompt": result.shrunkSystemPrompt as Any,
            "shrunkMutators": result.shrunkMutators,
            "steps": result.steps,
            "terminationReason": result.reason.rawValue,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        )
        let url = dir.appendingPathComponent("shrunk.json")
        try data.write(to: url)
        return url
    }

    // MARK: - Record mutation helpers

    private func joinedPrompt(_ messages: [RunRecord.PromptSnapshot.Message]) -> String {
        messages.map(\.text).joined(separator: "\n")
    }

    private func withMutators(_ mutators: [String], in record: RunRecord) -> RunRecord {
        var r = record
        r.prompt.mutators = mutators
        return r
    }

    private func withSystemPrompt(_ sp: String?, in record: RunRecord) -> RunRecord {
        var r = record
        r.config.systemPrompt = sp
        return r
    }

    private func withMaxTokens(_ t: Int, in record: RunRecord) -> RunRecord {
        var r = record
        r.config.maxTokens = t
        return r
    }

    /// Replaces the message list with a single user message carrying `text`.
    /// Bisection operates on the flat prompt string, so collapsing back to a
    /// single message is the simplest faithful representation of the
    /// shrunken input. Role is preserved from the last user message in the
    /// original record; falls back to `"user"` if there isn't one.
    private func withPromptText(_ text: String, in record: RunRecord) -> RunRecord {
        var r = record
        let lastUserRole = record.prompt.messages.last(where: { $0.role == "user" })?.role ?? "user"
        r.prompt.messages = [.init(role: lastUserRole, text: text)]
        return r
    }
}
