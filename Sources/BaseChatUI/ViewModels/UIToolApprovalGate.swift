import Foundation
import Observation
import BaseChatInference

/// A ``ToolApprovalGate`` backed by a MainActor-isolated pending-approval queue
/// that UI surfaces can observe and resolve.
///
/// The gate cooperates with ``ChatViewModel`` and the backing
/// ``GenerationQueue``: when the model emits a ``ToolCall``, the
/// coordinator awaits ``approve(_:)``. Depending on ``policy`` this either:
/// - returns immediately (``Policy/autoApprove`` or the cached "already
///   approved once" flag for ``Policy/askOncePerSession``), or
/// - appends the call to ``pending`` and suspends until the view calls
///   ``resolve(callId:with:)`` from the approval sheet's Approve/Deny buttons.
///
/// Because the gate is an `@Observable` class, SwiftUI views observing
/// ``pending`` automatically re-render when a new call arrives or the queue
/// drains.
///
/// ## Session boundary
///
/// The queue and the once-per-session latch are both cleared by
/// ``resetForNewSession()``. ``ChatViewModel/switchToSession(_:)`` invokes
/// this so an approval granted in one session doesn't silently carry over
/// into another. Hosts that drive the gate directly (tests, non-UI apps)
/// should call the same method when they swap sessions.
@Observable
@MainActor
public final class UIToolApprovalGate: ToolApprovalGate {

    // MARK: - Policy

    /// How aggressively the gate should prompt the user for each ``ToolCall``.
    ///
    /// - ``alwaysAsk`` — every call requires explicit approval.
    /// - ``askOncePerSession`` — the first call in a session requires
    ///   approval; subsequent calls auto-approve until ``resetForNewSession()``.
    /// - ``autoApprove`` — every call is approved silently.
    public enum Policy: Sendable, CaseIterable {
        case alwaysAsk
        case askOncePerSession
        case autoApprove
    }

    /// The current policy. Defaults to ``Policy/askOncePerSession`` — the
    /// behaviour the demo ships with. Hosts can expose this via a settings
    /// picker (see the Demo app's `ToolPolicyView`).
    public var policy: Policy = .askOncePerSession

    /// Calls awaiting a user decision, in arrival order. The first element
    /// is what a single-row approval sheet should present.
    public private(set) var pending: [ToolCall] = []

    // MARK: - Private state

    /// Waiters keyed by ``ToolCall/id``. A gate call appends to ``pending``
    /// and stores its continuation here; ``resolve(callId:with:)`` pops the
    /// matching entry and resumes.
    ///
    /// Marked `@ObservationIgnored` because mutating the dictionary would
    /// otherwise trigger view re-renders on every resume — the queue is the
    /// observable contract, the continuations are private plumbing.
    @ObservationIgnored
    private var waiters: [String: CheckedContinuation<ToolApprovalDecision, Never>] = [:]

    /// Set to `true` after the first successful approval under
    /// ``Policy/askOncePerSession``. Reset by ``resetForNewSession()``.
    @ObservationIgnored
    private var hasApprovedThisSession: Bool = false

    // MARK: - Init

    public init(policy: Policy = .askOncePerSession) {
        self.policy = policy
    }

    // MARK: - ToolApprovalGate

    /// Implements ``ToolApprovalGate/approve(_:)``.
    ///
    /// Actor hop: the protocol is `Sendable` and non-isolated, but this class
    /// is `@MainActor`. Swift bridges the call via an implicit `await` so the
    /// body runs on the main actor — the same actor the `@Observable` state
    /// and SwiftUI view updates live on.
    public func approve(_ call: ToolCall) async -> ToolApprovalDecision {
        switch policy {
        case .autoApprove:
            return .approved

        case .askOncePerSession where hasApprovedThisSession:
            return .approved

        case .alwaysAsk, .askOncePerSession:
            return await awaitDecision(for: call)
        }
    }

    // MARK: - View-facing API

    /// Called by the approval sheet to resolve the front-of-queue approval.
    ///
    /// Pops the matching entry from ``pending``, resumes the awaiting
    /// continuation, and — on ``ToolApprovalDecision/approved`` under
    /// ``Policy/askOncePerSession`` — flips the once-per-session latch so
    /// subsequent calls auto-approve.
    ///
    /// No-op if `callId` does not match a queued call (e.g. a stale sheet tap
    /// after the call was resolved elsewhere).
    public func resolve(callId: String, with decision: ToolApprovalDecision) {
        guard let continuation = waiters.removeValue(forKey: callId) else { return }
        pending.removeAll(where: { $0.id == callId })

        if case .approved = decision, policy == .askOncePerSession {
            hasApprovedThisSession = true
        }

        continuation.resume(returning: decision)
    }

    /// Clears the approval queue and the once-per-session latch so the next
    /// call under ``Policy/askOncePerSession`` prompts again. Any still-queued
    /// calls are denied with the reason "session reset" so their awaiting
    /// continuations don't leak.
    public func resetForNewSession() {
        hasApprovedThisSession = false
        let inFlight = waiters
        waiters.removeAll()
        pending.removeAll()
        for (_, continuation) in inFlight {
            continuation.resume(returning: .denied(reason: "session reset"))
        }
    }

    // MARK: - Private helpers

    private func awaitDecision(for call: ToolCall) async -> ToolApprovalDecision {
        await withCheckedContinuation { continuation in
            pending.append(call)
            waiters[call.id] = continuation
        }
    }
}
