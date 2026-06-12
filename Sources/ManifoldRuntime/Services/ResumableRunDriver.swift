import Foundation
import ManifoldInference

// MARK: - ResumableRunDriver
//
// P3b: the second shipped TurnDriver conformer. Wraps each TurnInput in a
// ConversationRun/RunStep lifecycle, checkpointing to RunStore before and
// after each step so the run survives app suspension.
//
// Design decisions (see PR body for full rationale):
//
// 1. executeTurn is a single-step adapter. The multi-step loop lives in
//    startRun(…) which ConversationRuntime.startRun(_:) calls. This keeps
//    the TurnDriver contract narrow (one delegation = one turn) while the
//    run API adds orchestration above it.
//
// 2. RunStore is required. The driver is constructed with the store; callers
//    that don't need resumable runs use SingleTurnDriver (the default).
//
// 3. Clock + ID injection for deterministic testing. ConversationRun and
//    RunStep accept externally-provided IDs and dates so tests produce stable
//    fixtures without harness hooks.
//
// 4. Internal mutable state is isolated behind ResumableRunState (an actor),
//    not a lock. Concurrency model follows the p2c invariants.
//
// 5. RunStore writes are @MainActor (protocol requirement). The driver calls
//    them via await MainActor.run { @MainActor in ... } which is safe because
//    MainActor.run's closure is Sendable only when the captures are Sendable.
//    ConversationRun/RunStep are Sendable value types, so the captures are clean.
//
// Invariant 7: adding this driver required zero engine-core edits.
// Invariant 6: run-level events ride RunEvent, never ConversationEvent.

// MARK: - ResumableRunState

/// Actor that guards the mutable state of a ``ResumableRunDriver``.
/// Keeps the driver `Sendable` by isolating mutations to one serial domain.
actor ResumableRunState {
    var activeRun: ConversationRun?
    var isPaused: Bool = false
    var isCancelled: Bool = false

    func setActiveRun(_ run: ConversationRun?) {
        activeRun = run
    }

    func updateActiveRun(_ run: ConversationRun) {
        activeRun = run
    }

    func requestPause() {
        isPaused = true
    }

    func requestCancel() {
        isCancelled = true
    }

    /// Clears transient flags at the start of a new run or on resume.
    func clearFlags() {
        isPaused = false
        isCancelled = false
    }

    func checkPaused() -> Bool { isPaused }
    func checkCancelled() -> Bool { isCancelled }
}

// MARK: - RunInputProvider

/// Supplies the ``TurnInput`` for each step in a ``ConversationRun``.
///
/// Conform this protocol to implement a custom multi-step orchestration
/// strategy. The default implementation (``FixedGoalRunInputProvider``)
/// synthesises a single `.send(text:)` turn from the run's `goal` and
/// returns `nil` on subsequent steps.
public protocol RunInputProvider: Sendable {
    /// Returns the ``TurnInput`` for the next step, or `nil` when the run
    /// is complete. Called before each step; `stepIndex` is 0-based.
    ///
    /// - Parameters:
    ///   - run:       Current run record.
    ///   - stepIndex: 0-based index of the step about to execute.
    ///   - prior:     The previous step's record, or `nil` for step 0.
    func nextInput(
        for run: ConversationRun,
        stepIndex: Int,
        prior: RunStep?
    ) async -> TurnInput?
}

/// Default ``RunInputProvider``: drives one `.send(text: goal)` turn on
/// step 0, returns `nil` on step 1+ so the run completes after a single
/// turn. Suitable for simple single-goal runs.
public struct FixedGoalRunInputProvider: RunInputProvider, Sendable {
    private let config: TurnConfig

    public init(config: TurnConfig = TurnConfig()) {
        self.config = config
    }

    public func nextInput(
        for run: ConversationRun,
        stepIndex: Int,
        prior: RunStep?
    ) async -> TurnInput? {
        guard stepIndex == 0 else { return nil }
        return TurnInput(
            sessionID: run.sessionID,
            kind: .send(text: run.goal),
            config: config
        )
    }
}

// MARK: - RunStoreProxy

/// Thin wrapper around ``RunStore`` that exposes best-effort checkpoint
/// calls with logging. Methods are `@MainActor` because the ``RunStore``
/// protocol is `@MainActor`-isolated. The `@unchecked Sendable` annotation
/// is safe because the single `store` reference is immutable (`let`) and is
/// only ever dereferenced from the `@MainActor` methods below — the existential
/// never escapes the main actor.
private final class RunStoreProxy: @unchecked Sendable {
    // Immutable after init; every use is gated behind a @MainActor method, so
    // the @MainActor-isolated `any RunStore` is never touched off the main actor.
    private let store: any RunStore

    // nonisolated init so ResumableRunDriver.init (non-actor) can create it.
    nonisolated init(_ store: any RunStore) {
        self.store = store
    }

    @MainActor
    func insertRun(_ run: ConversationRun) async {
        do { try await store.insertRun(run) } catch {
            Log.persistence.warning("ResumableRunDriver: insertRun failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    func updateRun(_ run: ConversationRun) async {
        do { try await store.updateRun(run) } catch {
            Log.persistence.warning("ResumableRunDriver: updateRun failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    func insertStep(_ step: RunStep) async {
        do { try await store.insertStep(step) } catch {
            Log.persistence.warning("ResumableRunDriver: insertStep failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    func updateStep(_ step: RunStep) async {
        do { try await store.updateStep(step) } catch {
            Log.persistence.warning("ResumableRunDriver: updateStep failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - ResumableRunDriver

/// ``TurnDriver`` that wraps each turn in a ``ConversationRun`` / ``RunStep``
/// lifecycle, checkpointing to ``RunStore`` before and after each step.
///
/// Inject into ``ConversationRuntime`` via the `turnDriver:` parameter of the
/// package init:
///
/// ```swift
/// let driver = ResumableRunDriver(runStore: myRunStore)
/// let runtime = ConversationRuntime(
///     messageStore: messageStore,
///     sessionStore: sessionStore,
///     inferenceService: service,
///     turnDriver: driver
/// )
/// ```
///
/// Drive runs via ``ConversationRuntime/startRun(_:using:)``.
///
/// ## Concurrency
///
/// Internal state is isolated behind ``ResumableRunState`` (an actor). All
/// ``RunStore`` access is `@MainActor` per the protocol requirement, routed
/// through ``RunStoreProxy`` to keep value captures clean.
///
/// ## Backward compatibility
///
/// When no run is active, `executeTurn` delegates to ``SingleTurnDriver``
/// so the driver is backward-compatible with direct
/// ``ConversationRuntime/processTurn(_:)`` callers — existing code that does
/// not use the run API is unaffected.
///
/// ## Invariants preserved
///
/// - Invariant 6: run-level events ride ``RunEvent``, never ``ConversationEvent``.
/// - Invariant 7: adding this driver required zero engine-core edits (EDGE).
public final class ResumableRunDriver: TurnDriver, @unchecked Sendable {
    // `@unchecked Sendable` is safe: all mutable state is isolated behind
    // the `ResumableRunState` actor. `RunStoreProxy` is `@MainActor`-isolated
    // and `Sendable` by explicit declaration above. No bare mutable references
    // escape the isolation boundaries.

    private let storeProxy: RunStoreProxy
    private let runState = ResumableRunState()

    // MARK: Init

    public init(runStore: any RunStore) {
        self.storeProxy = RunStoreProxy(runStore)
    }

    // MARK: TurnDriver

    /// Executes one turn. Delegates to ``SingleTurnDriver`` unconditionally;
    /// step bookkeeping is owned by the run loop in ``startRun(_:using:executor:taskRegistry:)``.
    package func executeTurn(
        _ input: TurnInput,
        executor: ConversationTurnExecutor,
        taskRegistry: ConversationTurnTaskRegistry,
        outcomeCompletion: ConversationTurnOutcomeCompletion?
    ) async throws -> ConversationStreamHandle? {
        try await SingleTurnDriver().executeTurn(
            input,
            executor: executor,
            taskRegistry: taskRegistry,
            outcomeCompletion: outcomeCompletion
        )
    }

    // MARK: Run lifecycle

    /// Starts a new ``ConversationRun`` and executes its steps until the
    /// provider signals completion.
    ///
    /// - Parameters:
    ///   - run:          The run record. The driver inserts it into ``RunStore``.
    ///   - provider:     Supplies the ``TurnInput`` for each step.
    ///   - executor:     The ``ConversationTurnExecutor`` from the runtime.
    ///   - taskRegistry: The ``ConversationTurnTaskRegistry`` from the runtime.
    /// - Returns: An `AsyncStream<RunEvent>` delivering lifecycle events until
    ///   the run reaches a terminal state.
    package func startRun(
        _ run: ConversationRun,
        using provider: any RunInputProvider,
        executor: ConversationTurnExecutor,
        taskRegistry: ConversationTurnTaskRegistry
    ) -> AsyncStream<RunEvent> {
        let storeProxy = self.storeProxy
        let runState = self.runState
        let driver = self

        return AsyncStream { continuation in
            Task {
                await runState.clearFlags()
                var currentRun = run

                // Persist as pending, then transition to running.
                await storeProxy.insertRun(currentRun)
                currentRun.status = .running
                currentRun.updatedAt = Date()
                await storeProxy.updateRun(currentRun)
                await runState.setActiveRun(currentRun)
                continuation.yield(.runStarted(
                    runID: currentRun.id,
                    sessionID: currentRun.sessionID,
                    goal: currentRun.goal
                ))

                var priorStep: RunStep? = nil
                var stepIndex = 0

                stepLoop: while true {
                    // Cancel check.
                    if await runState.checkCancelled() {
                        currentRun.status = .cancelled
                        currentRun.updatedAt = Date()
                        await storeProxy.updateRun(currentRun)
                        await runState.setActiveRun(nil)
                        continuation.yield(.runCancelled(runID: currentRun.id, stepCount: stepIndex))
                        break stepLoop
                    }

                    // Pause/resume cycle.
                    if await runState.checkPaused() {
                        currentRun.status = .paused
                        currentRun.updatedAt = Date()
                        await storeProxy.updateRun(currentRun)
                        continuation.yield(.runPaused(runID: currentRun.id, stepCount: stepIndex))

                        // Poll until un-paused or cancelled.
                        while await runState.checkPaused() {
                            if await runState.checkCancelled() { break }
                            try? await Task.sleep(for: .milliseconds(100))
                        }

                        if await runState.checkCancelled() {
                            currentRun.status = .cancelled
                            currentRun.updatedAt = Date()
                            await storeProxy.updateRun(currentRun)
                            await runState.setActiveRun(nil)
                            continuation.yield(.runCancelled(runID: currentRun.id, stepCount: stepIndex))
                            break stepLoop
                        }

                        currentRun.status = .running
                        currentRun.updatedAt = Date()
                        await storeProxy.updateRun(currentRun)
                        continuation.yield(.runResumed(runID: currentRun.id, stepCount: stepIndex))
                    }

                    // Step-limit check.
                    if let max = currentRun.maxSteps, stepIndex >= max {
                        currentRun.status = .completed
                        currentRun.stepCount = stepIndex
                        currentRun.updatedAt = Date()
                        await storeProxy.updateRun(currentRun)
                        await runState.setActiveRun(nil)
                        continuation.yield(.runCompleted(runID: currentRun.id, stepCount: stepIndex))
                        break stepLoop
                    }

                    // Ask provider for next input.
                    guard let turnInput = await provider.nextInput(
                        for: currentRun,
                        stepIndex: stepIndex,
                        prior: priorStep
                    ) else {
                        currentRun.status = .completed
                        currentRun.stepCount = stepIndex
                        currentRun.updatedAt = Date()
                        await storeProxy.updateRun(currentRun)
                        await runState.setActiveRun(nil)
                        continuation.yield(.runCompleted(runID: currentRun.id, stepCount: stepIndex))
                        break stepLoop
                    }

                    // Insert the step record before executing the turn — mirrors
                    // the #1606 register-before-enqueue discipline: checkpoint
                    // first so the step is visible if the process dies during
                    // execution.
                    var step = RunStep(
                        runID: currentRun.id,
                        stepIndex: stepIndex,
                        turnInput: turnInput
                    )
                    await storeProxy.insertStep(step)
                    continuation.yield(.stepStarted(
                        runID: currentRun.id,
                        stepIndex: stepIndex,
                        stepID: step.id
                    ))

                    // Execute the turn, capturing the outcome for step attribution.
                    let outcomeCompletion = ConversationTurnOutcomeCompletion()
                    do {
                        let handle = try await driver.executeTurn(
                            turnInput,
                            executor: executor,
                            taskRegistry: taskRegistry,
                            outcomeCompletion: outcomeCompletion
                        )
                        // Wait for the turn to fully complete before advancing.
                        if handle != nil {
                            let outcome = await outcomeCompletion.value()
                            step.messageID = outcome.assistantMessage?.id
                        }
                    } catch {
                        let reason = error.localizedDescription
                        step.isFailed = true
                        step.failureReason = reason
                        step.updatedAt = Date()
                        await storeProxy.updateStep(step)
                        currentRun.status = .failed
                        currentRun.updatedAt = Date()
                        await storeProxy.updateRun(currentRun)
                        await runState.setActiveRun(nil)
                        continuation.yield(.stepFailed(
                            runID: currentRun.id,
                            stepIndex: stepIndex,
                            stepID: step.id,
                            reason: reason
                        ))
                        continuation.yield(.runFailed(runID: currentRun.id, reason: reason))
                        break stepLoop
                    }

                    // Mark step complete and checkpoint.
                    step.isCompleted = true
                    step.updatedAt = Date()
                    await storeProxy.updateStep(step)
                    continuation.yield(.stepCompleted(
                        runID: currentRun.id,
                        stepIndex: stepIndex,
                        stepID: step.id,
                        messageID: step.messageID
                    ))

                    // Advance the step counter.
                    priorStep = step
                    stepIndex += 1
                    currentRun.stepCount = stepIndex
                    currentRun.updatedAt = Date()
                    await runState.updateActiveRun(currentRun)
                    await storeProxy.updateRun(currentRun)
                }

                continuation.finish()
            }
        }
    }

    // MARK: Pause / Resume / Cancel

    /// Requests that the active run pause after its current step.
    /// Returns immediately; the run emits ``RunEvent/runPaused`` when
    /// it actually suspends.
    public func pauseRun() async {
        await runState.requestPause()
    }

    /// Requests that a paused run resume execution. Returns immediately;
    /// the run emits ``RunEvent/runResumed`` when it continues.
    public func resumeRun() async {
        await runState.clearFlags()
    }

    /// Requests that the active run cancel. Returns immediately;
    /// the run emits ``RunEvent/runCancelled`` when it stops.
    public func cancelRun() async {
        await runState.requestCancel()
    }
}
