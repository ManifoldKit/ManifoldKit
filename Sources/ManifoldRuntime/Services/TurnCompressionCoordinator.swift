import Foundation
import ManifoldInference

/// Per-turn compression coordination seam, extracted from
/// ``ConversationTurnExecutor`` (#1725, step P3a). Owns the two
/// compress-and-replace sequences plus the shared background-summarisation
/// generate closure both paths drive:
///
/// - **Pre-turn** — ``compressBeforeTurnIfNeeded(sessionID:)`` runs at the top
///   of the send flow, BEFORE the user message is inserted, so the
///   just-submitted action always falls outside the compressed segment.
///   Failures throw to the caller: the host's ordering invariant depends on
///   compression completing first, so a pre-turn failure aborts the turn.
/// - **Post-turn** — ``compressAfterTurnIfNeeded(sessionID:promptTokens:hookRegistry:)``
///   runs after the turn's terminal `streamFinished`, at the very end of the
///   generation path. Failures log and continue — the generation has already
///   succeeded and must not be retroactively failed by a compression error.
///
/// Both paths preserve the event bracket the characterization goldens pin:
/// `.compressionTriggered` (emitted after the policy resolves but before the
/// store mutation, carrying the real removed-record IDs) followed by
/// `.historyCompressed` (after the replacement insert).
///
/// The post-turn path also owns the **preCompact** hook call. v1 contract:
/// the hook is observational — a `block: true` result logs a warning but does
/// NOT prevent compression (there is no mutation channel for the history
/// shape). Do not "fix" this without a major-version contract change.
///
/// Sendability discipline (invariant 5): this holds the ``TurnEventEmitter``
/// — a bare `@Sendable (ConversationEvent) -> Void` sink — never a
/// `@MainActor`-capturing wrapper. The only main-actor state read is the
/// explicit `@MainActor` ``readContextWindowSize()`` hop.
struct TurnCompressionCoordinator: Sendable {
    private let persistence: ConversationPersistencePort
    private let inferenceService: InferenceService
    private let events: TurnEventEmitter
    private let preTurnPolicy: (any PreTurnCompressionPolicy)?
    private let postTurnPolicy: (any CompressionPolicy)?

    init(
        persistence: ConversationPersistencePort,
        inferenceService: InferenceService,
        events: TurnEventEmitter,
        preTurnPolicy: (any PreTurnCompressionPolicy)?,
        postTurnPolicy: (any CompressionPolicy)?
    ) {
        self.persistence = persistence
        self.inferenceService = inferenceService
        self.events = events
        self.preTurnPolicy = preTurnPolicy
        self.postTurnPolicy = postTurnPolicy
    }

    struct PreTurnCompressionEmptyResultError: LocalizedError, Sendable {
        var errorDescription: String? {
            "Pre-turn compression returned an empty history."
        }
    }

    // MARK: Pre-turn

    /// Pre-turn compression: runs before the user message is appended so
    /// the just-submitted action always falls outside the compressed
    /// segment. Only runs for `.send` turns (not regenerate / edit / branch).
    /// Failures throw to the caller — unlike post-turn compression which
    /// logs and continues, pre-turn failure aborts the turn because the
    /// host's ordering invariant depends on compression completing first.
    func compressBeforeTurnIfNeeded(sessionID: UUID) async throws {
        guard let preTurnPolicy else { return }
        let existingHistory: [ChatMessage]
        do {
            // Generation-bound fetch: the policy's summarisation `generate`
            // closure sends this history to a real backend, so orphan tool
            // calls must be healed first (#629). See HealedHistoryFetch.swift.
            existingHistory = try await persistence.fetchHealedMessages(sessionID: sessionID)
        } catch {
            throw ConversationError.persistence(error)
        }
        let lastPromptTokens = existingHistory.last(where: { $0.role == .assistant })?.promptTokens
        guard preTurnPolicy.shouldCompressBeforeTurn(
            messageCount: existingHistory.count,
            lastPromptTokens: lastPromptTokens
        ) else { return }

        let generate = makeCompressionGenerateClosure()
        let systemPrompt = await persistence.fetchSession(sessionID: sessionID)?.systemPrompt
        let compressed: [ChatMessage]
        do {
            compressed = try await preTurnPolicy.compressBeforeTurn(
                history: existingHistory,
                sessionID: sessionID,
                systemPrompt: systemPrompt,
                generate: generate
            )
        } catch {
            throw ConversationError.preTurnCompressionFailed(error)
        }
        guard !compressed.isEmpty else {
            throw ConversationError.preTurnCompressionFailed(
                PreTurnCompressionEmptyResultError()
            )
        }
        // "Before" bracket for the `.historyCompressed` "after" signal.
        // The removed set is computed from the policy's replacement
        // output (records present before but absent from `compressed`)
        // so the IDs are accurate rather than a placeholder — emitting
        // it here, after `compressBeforeTurn` resolves but before the
        // store mutation, keeps it ordered ahead of `.historyCompressed`
        // without fabricating which records will actually be dropped.
        let retainedIDs = Set(compressed.map(\.id))
        let removedIDs = existingHistory.compactMap {
            retainedIDs.contains($0.id) ? nil : $0.id
        }
        events.emit(.compressionTriggered(removed: removedIDs, reason: .contextWindowExceeded))
        do {
            try await persistence.deleteMessages(for: sessionID)
            for message in compressed {
                try await persistence.insertMessage(message)
            }
        } catch {
            throw ConversationError.persistence(error)
        }
        events.emit(.historyCompressed(sessionID: sessionID, insertedRecords: compressed))
        await preTurnPolicy.postCompressBeforeTurn(
            sessionID: sessionID,
            insertedRecords: compressed
        )
    }

    // MARK: Post-turn

    /// Compression check: ask the policy whether the context is full enough
    /// to warrant compression. Skipped when no token usage is available
    /// (policy can't make a meaningful decision without promptTokens) or
    /// when the backend doesn't report a context size (contextSize == 0).
    func compressAfterTurnIfNeeded(
        sessionID: UUID,
        promptTokens: Int?,
        hookRegistry: HookRegistry?
    ) async {
        guard let postTurnPolicy, let promptTokens else { return }
        let contextSize = await readContextWindowSize()
        let contextUtilization = contextSize > 0 ? Double(promptTokens) / Double(contextSize) : 0
        guard contextSize > 0 && postTurnPolicy.shouldCompress(promptTokens: promptTokens, contextSize: contextSize, contextUtilization: contextUtilization) else { return }

        let history: [ChatMessage]
        do {
            // Generation-bound fetch: the policy's summarisation `generate`
            // closure sends this history to a real backend, so orphan tool
            // calls must be healed first (#629). See HealedHistoryFetch.swift.
            history = try await persistence.fetchHealedMessages(sessionID: sessionID)
        } catch {
            Log.inference.warning("CompressionPolicy: fetchMessages failed, skipping compression: \(error.localizedDescription, privacy: .public)")
            return
        }

        let generate = makeCompressionGenerateClosure()
        let systemPrompt = await persistence.fetchSession(sessionID: sessionID)?.systemPrompt

        // preCompact hook: v1 is observational. The plan's hook
        // contract documents that preCompact CANNOT block compression
        // (there's no mutation channel for the history shape); a
        // hook that returns block:true logs a warning but compression
        // still runs. Emit `.hookFired(event: "preCompact", ...)`
        // regardless so observability stays consistent.
        if let hookRegistry {
            let input = HookInput(
                event: .preCompact,
                sessionID: sessionID,
                toolName: nil,
                toolArguments: nil
            )
            let output = await hookRegistry.run(input)
            events.emit(.hookFired(event: "preCompact", sessionID: sessionID))
            if output.block {
                Log.inference.warning(
                    "preCompact hook returned block:true — block is not honoured for compaction in v1; ignoring and proceeding with compression."
                )
            }
        }

        do {
            let compressed = try await postTurnPolicy.compress(
                history: history,
                sessionID: sessionID,
                systemPrompt: systemPrompt,
                generate: generate
            )
            // Guard against an empty result — deleting all messages
            // without re-inserting anything would silently wipe the
            // conversation. Treat this as a policy error; preserve the
            // existing history rather than destroying it.
            guard !compressed.isEmpty else {
                Log.inference.warning(
                    "CompressionPolicy.compress returned empty history (sessionID=\(sessionID, privacy: .private)); skipping replacement to preserve existing messages"
                )
                return
            }
            // "Before" bracket for `.historyCompressed`. Removed IDs are
            // derived from the policy's replacement set (records present
            // in `history` but absent from `compressed`) so the event
            // carries the real dropped records, emitted ahead of the
            // store mutation and the "after" `.historyCompressed`.
            let retainedIDs = Set(compressed.map(\.id))
            let removedIDs = history.compactMap {
                retainedIDs.contains($0.id) ? nil : $0.id
            }
            events.emit(.compressionTriggered(removed: removedIDs, reason: .contextWindowExceeded))
            try await persistence.deleteMessages(for: sessionID)
            for message in compressed {
                try await persistence.insertMessage(message)
            }
            events.emit(.historyCompressed(sessionID: sessionID, insertedRecords: compressed))
            await postTurnPolicy.postCompress(sessionID: sessionID, insertedRecords: compressed)
        } catch {
            Log.inference.warning("CompressionPolicy.compress failed (sessionID=\(sessionID, privacy: .private)): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Shared generate closure

    /// Returns a `@Sendable` closure that drives a background inference call
    /// for summarisation. Used by both pre-turn and post-turn compression paths.
    private func makeCompressionGenerateClosure() -> @Sendable ([ChatMessage]) async throws -> String {
        let inferenceService = self.inferenceService
        return { messages in
            let structured = messages
                .filter { $0.kind.isWireVisible }
                .map { record -> StructuredMessage in
                    let role = record.kind.backendRole ?? record.role
                    return StructuredMessage(role: role.rawValue, parts: record.contentParts)
                }
            let (token, compressStream) = try await inferenceService.enqueueAsync(
                structuredMessages: structured,
                priority: .background
            )
            var result = ""
            var consumer = GenerationStreamConsumer(loopDetectionEnabled: false)
            do {
                for try await event in compressStream.events {
                    try Task.checkCancellation()
                    if case .appendText(let chunk) = consumer.handle(event) {
                        result += chunk
                    }
                }
            } catch {
                await inferenceService.cancelAsync(token)
                throw error
            }
            return result
        }
    }

    /// Reads the backend's context window size from the main actor.
    /// Returns 0 when unavailable — callers treat 0 as "skip compression".
    @MainActor
    private func readContextWindowSize() async -> Int {
        inferenceService.capabilities?.contextWindowSize ?? 0
    }
}
