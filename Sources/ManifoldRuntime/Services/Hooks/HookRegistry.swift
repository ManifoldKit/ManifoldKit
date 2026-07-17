import Foundation

/// Synchronous hook dispatch surface. Distinct from the existing
/// `GenerationHook` observability protocol: handlers here may mutate
/// (sanitize) tool inputs or block dispatch entirely.
///
/// W2C will wire callsites:
///   - `.preToolUse` before `dispatchResult()` in `GenerationToolDispatchLoop`.
///   - `.preCompact` at the `CompressionPolicy.compress` invocation in
///     `ConversationTurnExecutor.runGenerationTurn` (~line 957).
/// This file is intentionally callsite-free — it ships the actor + value
/// types so the wiring PR is a localized diff.
public actor HookRegistry {
    public typealias Handler = @Sendable (HookInput) async -> HookOutput

    private var handlers: [HookEvent: [Handler]] = [:]
    private let clock: any Clock<Duration>
    private let timeout: Duration

    /// Injectable clock for deterministic timeout tests. Defaults to
    /// `ContinuousClock()` for production use.
    public init(
        clock: any Clock<Duration> = ContinuousClock(),
        timeout: Duration = .seconds(5)
    ) {
        self.clock = clock
        self.timeout = timeout
    }

    public func register(_ event: HookEvent, handler: @escaping Handler) {
        handlers[event, default: []].append(handler)
    }

    /// Runs every registered handler for `input.event` in registration order.
    /// If any handler returns `block: true`, the chain short-circuits and
    /// that output is returned. `updatedInput` from earlier handlers is
    /// threaded into later handlers' inputs (so a sanitizer can chain). A
    /// handler that exceeds `timeout` is cancelled and treated as
    /// passthrough — a slow hook must never deadlock the turn loop.
    public func run(_ input: HookInput) async -> HookOutput {
        let chain = handlers[input.event] ?? []
        guard !chain.isEmpty else { return .passthrough }

        var current = input
        var lastOutput: HookOutput = .passthrough

        for handler in chain {
            let result = await runWithTimeout(handler: handler, input: current)
            if result.block {
                return result
            }
            if let updated = result.updatedInput {
                // Thread the sanitized input into the next handler so a
                // chain of sanitizers can layer narrowing transforms.
                current = HookInput(
                    event: current.event,
                    sessionID: current.sessionID,
                    toolName: current.toolName,
                    toolArguments: updated,
                    completedTurn: current.completedTurn
                )
                lastOutput = result
            } else if result != .passthrough {
                lastOutput = result
            }
        }
        return lastOutput
    }

    /// Distinguishes "handler finished" from "timeout fired" so a handler
    /// returning *after* cancellation can't be mistaken for a real result.
    private enum RaceWinner: Sendable {
        case handler(HookOutput)
        case timeout
    }

    private func runWithTimeout(
        handler: @escaping Handler,
        input: HookInput
    ) async -> HookOutput {
        // Race: handler vs. clock timeout. Whichever finishes first wins;
        // the loser is cancelled. The clock is injectable so tests don't
        // burn wall-clock time. We tag results with their source so a
        // late-returning handler (e.g. one that swallows cancellation) is
        // discarded if the timeout already won.
        let timeout = self.timeout
        let clock = self.clock
        return await withTaskGroup(of: RaceWinner?.self) { group in
            group.addTask { @Sendable in
                let output = await handler(input)
                return .handler(output)
            }
            group.addTask { @Sendable in
                do {
                    try await clock.sleep(for: timeout)
                    return .timeout
                } catch {
                    // Sleep was cancelled — handler won the race.
                    return nil
                }
            }
            // First non-nil result is the race winner. Cancel siblings.
            for await winner in group {
                guard let winner else { continue }
                group.cancelAll()
                switch winner {
                case .handler(let output):
                    return output
                case .timeout:
                    // Treat slow hook as no-op rather than failing the turn.
                    return .passthrough
                }
            }
            return .passthrough
        }
    }
}
