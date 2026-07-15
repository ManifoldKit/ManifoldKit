import Foundation
import os

/// Races an async operation against a wall-clock timeout, returning the
/// timeout fallback if the operation doesn't complete in time.
///
/// Mirrors `ManifoldMCP`'s `InternalMCPSession.withTimeout`: an unstructured-task
/// race, not `withThrowingTaskGroup`. The group variant blocks on ALL child
/// tasks at scope exit, so if `operation` is suspended forever — a genuinely
/// hung local-backend generation stream that never yields and never checks
/// cancellation — that wait itself would never return. Cancelling the losing
/// operation task is a best-effort signal: it unblocks the fuzz iteration
/// loop immediately, but does not guarantee the abandoned task actually stops
/// doing work in the background (the same caveat applies to leet-llm's
/// process-tree kill, and to MCP's stdio read-loop cancellation).
///
/// Used to bound `EventRecorder.consume` in the fuzz single-turn and
/// session-script runners: before this, only the OpenAI cloud path had any
/// per-request timeout (`OpenAIFuzzFactory.requestTimeout`, enforced at the
/// HTTP transport layer); local backends (Ollama, Foundation, mock, chaos)
/// generated in-process with no bound at all, so a hung generation stalled
/// the whole campaign.
enum GenerationTimeout {
    static func run<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async -> T,
        onTimeout: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            func claimResume() -> Bool {
                resumed.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
            }

            let operationTask = Task {
                let value = await operation()
                if claimResume() { continuation.resume(returning: value) }
            }

            Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                guard claimResume() else { return }
                operationTask.cancel()
                continuation.resume(returning: onTimeout())
            }
        }
    }
}
