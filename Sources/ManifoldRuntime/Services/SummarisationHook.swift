import Foundation
import ManifoldInference

// MARK: - SummarisationPolicy

/// Threshold-based trigger for ``SummarisationHook``.
///
/// After every successful generation turn, the hook asks the policy whether
/// the context is full enough to warrant summarisation. When the policy
/// returns `true`, the hook selects the oldest non-pinned `.chat` turns,
/// summarises them via the supplied ``DialogueSummariser``, writes a
/// `.memory("summary")` message, and deletes the turns that were folded in.
///
/// The default implementation ``ThresholdSummarisationPolicy`` fires when
/// context utilization crosses a configurable ratio (default 0.8). Hosts that
/// want finer control can supply their own conformance.
public protocol SummarisationPolicy: Sendable {
    /// Returns `true` if the runtime should summarise the oldest dialogue turns.
    ///
    /// - Parameters:
    ///   - promptTokens: Tokens consumed by the last prompt (history + slots).
    ///   - contextSize: Backend context window size. 0 when unknown; treat as "skip".
    ///   - contextUtilization: `promptTokens / contextSize`. 0.0 when `contextSize == 0`.
    func shouldSummarise(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool
}

// MARK: - ThresholdSummarisationPolicy

/// Default ``SummarisationPolicy`` — fires when utilization crosses a ratio.
public struct ThresholdSummarisationPolicy: SummarisationPolicy {

    /// Fraction of the context window that must be consumed before summarisation
    /// is triggered. Defaults to 0.8 (80 %).
    public let utilizationThreshold: Double

    public init(utilizationThreshold: Double = 0.8) {
        self.utilizationThreshold = utilizationThreshold.clamped(to: 0.0...1.0)
    }

    public func shouldSummarise(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
        guard contextSize > 0 else { return false }
        return contextUtilization >= utilizationThreshold
    }
}

// MARK: - SummarisationHook

/// A ``GenerationHook`` that performs rolling dialogue summarisation.
///
/// Wired into ``ConversationRuntime`` via the `generationHooks` parameter.
/// After each successful generation turn, the hook:
///
/// 1. Checks whether ``SummarisationPolicy/shouldSummarise(promptTokens:contextSize:contextUtilization:)``
///    returns `true`.
/// 2. If yes, fetches all messages for the session and selects the oldest
///    non-pinned `.chat` turns (preserving `recentTurnsToPreserve` turns
///    verbatim so the model has immediate context).
/// 3. Calls ``DialogueSummariser/summarise(turns:using:)`` on the candidate
///    turns.
/// 4. Writes a new message with `kind: .memory("summary")` at the position
///    of the first folded turn.
/// 5. Deletes the original turns that were summarised.
///
/// Summarisation failures are logged and never abort the turn loop. An empty
/// summary result from the summariser is treated as a failure — no messages
/// are deleted.
///
/// ## Opt-in design
///
/// The hook is not installed by default. Hosts inject it via:
///
/// ```swift
/// let hook = SummarisationHook(
///     messageStore: store,
///     backend: myBackend,
///     sessionStore: sessionStore,
///     summariser: DefaultDialogueSummariser(),
///     policy: ThresholdSummarisationPolicy(utilizationThreshold: 0.8),
///     contextSizeProvider: { [weak inferenceService] in
///         inferenceService?.capabilities?.contextWindowSize ?? 0
///     }
/// )
///
/// let runtime = ConversationRuntime(
///     messageStore: store,
///     inferenceService: inferenceService,
///     generationHooks: [hook]
/// )
/// ```
public final class SummarisationHook: GenerationHook, @unchecked Sendable {

    // MARK: - Configuration

    /// The number of the most recent non-pinned turns to preserve verbatim.
    /// These turns are never folded into the summary — the backend needs them
    /// to continue the conversation naturally.
    public let recentTurnsToPreserve: Int

    // MARK: - Ports

    private let messageStore: any MessageStore
    private let backend: any InferenceBackend
    private let sessionStore: (any SessionStore)?
    private let summariser: any DialogueSummariser
    private let policy: any SummarisationPolicy
    /// Returns the backend's current context window size.
    /// Called on each post-generation turn to decide whether summarisation is needed.
    /// The provider is a closure rather than a direct `InferenceService` reference
    /// to keep `SummarisationHook` independent of `InferenceService` internals and
    /// to let tests inject a fixed value without a full service.
    private let contextSizeProvider: @Sendable () async -> Int

    // MARK: - Init

    /// Creates a hook ready to be registered with ``ConversationRuntime``.
    ///
    /// - Parameters:
    ///   - messageStore: Message persistence port. Must be the same store
    ///     that the runtime uses so that inserts and deletes are visible to
    ///     subsequent turns.
    ///   - backend: The inference backend used for summarisation calls.
    ///     **Pass a dedicated backend — not the same instance the runtime drives.**
    ///     Backends such as `LlamaBackend` and `MLXBackend` permit only one active
    ///     `generate()` call at a time; sharing the runtime's backend can corrupt
    ///     KV-cache state or trigger a single-active-generation contract assertion.
    ///     Use a separate loaded instance or `ConversationRuntime/auxiliaryInferenceService`.
    ///   - sessionStore: Optional session store for reading `pinnedMessageIDs`.
    ///     When `nil`, the hook treats all messages as unpinned.
    ///   - summariser: The strategy for turning a window of turns into a
    ///     summary string.
    ///   - policy: Controls when summarisation fires.
    ///   - recentTurnsToPreserve: How many of the most-recent non-pinned turns
    ///     to keep verbatim. Must be ≥ 1; values below 1 are clamped to 1.
    ///   - contextSizeProvider: Returns the backend's context window size (in
    ///     tokens). Return 0 to unconditionally skip summarisation for a turn.
    public init(
        messageStore: any MessageStore,
        backend: any InferenceBackend,
        sessionStore: (any SessionStore)? = nil,
        summariser: any DialogueSummariser = DefaultDialogueSummariser(),
        policy: any SummarisationPolicy = ThresholdSummarisationPolicy(),
        recentTurnsToPreserve: Int = 4,
        contextSizeProvider: @escaping @Sendable () async -> Int
    ) {
        self.messageStore = messageStore
        self.backend = backend
        self.sessionStore = sessionStore
        self.summariser = summariser
        self.policy = policy
        self.recentTurnsToPreserve = max(1, recentTurnsToPreserve)
        self.contextSizeProvider = contextSizeProvider
    }

    // MARK: - GenerationHook

    public func willBeginTurn(sessionID: UUID) async {}

    public func postGeneration(_ turn: CompletedTurn) async {
        guard let promptTokens = turn.promptTokens else { return }

        let contextSize = await contextSizeProvider()
        guard contextSize > 0 else { return }

        let utilization = Double(promptTokens) / Double(contextSize)
        guard policy.shouldSummarise(
            promptTokens: promptTokens,
            contextSize: contextSize,
            contextUtilization: utilization
        ) else { return }

        await performSummarisation(sessionID: turn.sessionID)
    }

    // MARK: - HookRegistry adapter (B.2)

    /// Exposes this hook's summarisation trigger as a ``HookRegistry``
    /// `.postGeneration` handler, so hosts standardising on the unified
    /// registry seam can register `SummarisationHook` there instead of
    /// threading it through ``ConversationRuntime``'s separate
    /// `generationHooks` parameter:
    ///
    /// ```swift,no-build
    /// await registry.register(.postGeneration, handler: summarisationHook.makeHookHandler())
    /// ```
    ///
    /// A thin adapter over the existing ``postGeneration(_:)`` — the trigger
    /// policy and summarisation logic are not duplicated. Returns
    /// `.passthrough` unconditionally: summarisation is observational from
    /// the registry's point of view (it mutates the message store directly,
    /// not the turn's `HookOutput`).
    public func makeHookHandler() -> HookRegistry.Handler {
        { [weak self] input in
            guard let self, let turn = input.completedTurn else { return .passthrough }
            await self.postGeneration(turn)
            return .passthrough
        }
    }

    // MARK: - Summarisation

    private func performSummarisation(sessionID: UUID) async {
        // Fetch current history — if this fails, log and bail. Preserving
        // existing history is always the right fallback. Generation-bound
        // fetch: folded turns are handed to the summariser's backend call,
        // so orphan tool calls must be healed first (#629); deletion targets
        // below resolve by message ID, which healing preserves. See
        // HealedHistoryFetch.swift.
        let history: [ChatMessage]
        do {
            history = try await messageStore.fetchRecentHealedMessages(
                for: sessionID,
                limit: 10_000
            )
        } catch {
            Log.inference.warning(
                "SummarisationHook: fetchMessages failed, skipping summarisation (sessionID=\(sessionID, privacy: .private)): \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        // Resolve pinned IDs. Missing session store → treat all as unpinned
        // (there is no store that could hold a pin). A store that IS present
        // but fails to fetch is a different case: pin status is unknown, and
        // folding/deleting messages under that uncertainty could destroy a
        // pinned message, so abort the whole cycle rather than guess "[]".
        let pinnedIDs: Set<UUID>
        if let sessionStore {
            do {
                let sessions = try await sessionStore.fetchSessions()
                pinnedIDs = sessions.first(where: { $0.id == sessionID })?.pinnedMessageIDs ?? []
            } catch {
                Log.inference.warning(
                    "SummarisationHook: sessionStore.fetchSessions failed, aborting summarisation because pin status is unknown (sessionID=\(sessionID, privacy: .private)): \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        } else {
            pinnedIDs = []
        }

        // Candidates: only `.chat`-kind records, never pinned.
        let chatTurns = history.filter { $0.kind == .chat && !pinnedIDs.contains($0.id) }

        // Need more than `recentTurnsToPreserve` turns to have anything to fold.
        guard chatTurns.count > recentTurnsToPreserve else { return }

        let foldCount = chatTurns.count - recentTurnsToPreserve
        let toFold = Array(chatTurns.prefix(foldCount))

        guard !toFold.isEmpty else { return }

        // Summarise the selected window via the injected summariser.
        let summaryText: String
        do {
            summaryText = try await summariser.summarise(turns: toFold, using: backend)
        } catch {
            Log.inference.warning(
                "SummarisationHook: summariser failed, skipping (sessionID=\(sessionID, privacy: .private)): \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        // Guard against empty output — deleting source turns without a
        // meaningful summary would silently lose conversation content.
        guard !summaryText.isEmpty else {
            Log.inference.warning(
                "SummarisationHook: summariser returned empty string, skipping (sessionID=\(sessionID, privacy: .private))"
            )
            return
        }

        // Anchor the summary at the timestamp of the first folded turn so it
        // sorts naturally before the turns that were preserved verbatim.
        let summaryTimestamp = toFold[0].timestamp
        let summaryRecord = ChatMessage(
            role: .system,
            content: summaryText,
            timestamp: summaryTimestamp,
            sessionID: sessionID,
            kind: .memory("summary")
        )

        // Insert the summary first, then delete the source turns. This
        // ordering means a persistence failure during deletion leaves us
        // with a redundant summary record rather than a hole in history —
        // the safe direction.
        do {
            try await messageStore.insertMessage(summaryRecord)
        } catch {
            Log.inference.warning(
                "SummarisationHook: insertMessage(summary) failed, aborting (sessionID=\(sessionID, privacy: .private)): \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        for record in toFold {
            do {
                try await messageStore.deleteMessage(record.id)
            } catch {
                // Partial deletion is acceptable — the summary record is
                // already committed. Log so the inconsistency is observable.
                Log.inference.warning(
                    "SummarisationHook: deleteMessage(\(record.id, privacy: .private)) failed (sessionID=\(sessionID, privacy: .private)): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

// MARK: - Comparable clamping helper

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
