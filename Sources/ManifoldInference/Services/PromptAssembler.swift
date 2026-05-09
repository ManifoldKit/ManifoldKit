import Foundation

/// Assembles prompt slots and conversation history into a context-budgeted prompt.
///
/// The assembler follows this algorithm:
/// 1. Calculate token cost of each enabled slot's content (capped by ``PromptSlot/tokenBudget``).
/// 2. Sort slots by ``PromptSlotPosition/sortIndex(messageCount:)``.
/// 3. Sum slot tokens and subtract from the context budget (along with ``responseBuffer``).
/// 4. Allocate remaining budget to message history.
/// 5. Trim messages newest-first (same strategy as ``ContextWindowManager``).
/// 6. Insert history-positioned slots into the message stream at their resolved depth.
/// 7. Return an ``AssembledPrompt`` with ordered slots, trimmed messages, total tokens, and per-slot breakdown.
public enum PromptAssembler {

    /// Assembles slots and messages using context window size from `BackendCapabilities`.
    ///
    /// Convenience overload that reads `contextWindowSize` directly from capabilities,
    /// so callers don't need to thread the value separately.
    public static func assemble(
        slots: [PromptSlot],
        messages: [ChatMessageRecord],
        systemPrompt: String?,
        capabilities: BackendCapabilities,
        responseBuffer: Int = 512,
        tokenizer: TokenizerProvider? = nil,
        policy: BudgetPolicy = .default
    ) -> AssembledPrompt {
        assemble(
            slots: slots,
            messages: messages,
            systemPrompt: systemPrompt,
            contextSize: capabilities.contextWindowSize,
            responseBuffer: responseBuffer,
            tokenizer: tokenizer,
            policy: policy
        )
    }

    /// Assembles slots and messages into a budgeted prompt.
    ///
    /// - Parameters:
    ///   - slots: Prompt slots to include. Disabled slots are skipped.
    ///   - messages: Full conversation history in chronological order.
    ///   - systemPrompt: Optional system prompt (assembled as a slot with id "system" at ``PromptSlotPosition/systemPreamble``).
    ///   - contextSize: Total context window size in tokens.
    ///   - responseBuffer: Tokens reserved for the model's response.
    ///   - tokenizer: Optional tokenizer. Falls back to ``HeuristicTokenizer`` when nil.
    ///   - policy: Per-role budget policy. Defaults to ``BudgetPolicy/default`` —
    ///     the priority order from #110 with no role-level caps.
    /// - Returns: An ``AssembledPrompt`` containing resolved slots, trimmed messages, and budget info.
    public static func assemble(
        slots: [PromptSlot],
        messages: [ChatMessageRecord],
        systemPrompt: String?,
        contextSize: Int,
        responseBuffer: Int = 512,
        tokenizer: TokenizerProvider? = nil,
        policy: BudgetPolicy = .default
    ) -> AssembledPrompt {
        let tok = tokenizer ?? HeuristicTokenizer()

        // 1. Build the system prompt slot if provided
        var allSlots = slots.filter { $0.isEnabled }
        if let systemPrompt, !systemPrompt.isEmpty {
            let systemSlot = PromptSlot(
                id: "system",
                content: systemPrompt,
                position: .systemPreamble,
                role: .system,
                label: "System Prompt"
            )
            allSlots.insert(systemSlot, at: 0)
        }

        // 2. Resolve each slot's token cost (per-slot tokenBudget cap first).
        var resolvedSlots: [ResolvedSlot] = allSlots.map { slot in
            let rawCount = tok.tokenCount(slot.content)
            let tokenCount = slot.tokenBudget.map { min(rawCount, $0) } ?? rawCount
            return ResolvedSlot(
                id: slot.id, label: slot.label, content: slot.content,
                tokenCount: tokenCount, position: slot.position, role: slot.role
            )
        }

        // 3. Apply per-role caps (combined token usage across slots in the role).
        // Slots in the same role are clamped in input-array order — earlier
        // slots get the budget first; later ones drop to whatever remains.
        resolvedSlots = applyRoleCaps(to: resolvedSlots, policy: policy)

        // 4. Apply role-priority trimming so slot+responseBuffer fits in contextSize.
        // Lowest-priority roles are trimmed first; .system is never trimmed.
        let slotBudget = max(0, contextSize - responseBuffer)
        resolvedSlots = applyRolePriorityTrimming(
            to: resolvedSlots, slotBudget: slotBudget, policy: policy
        )

        // Drop slots whose final token count is zero — they no longer contribute
        // content, and keeping them would still inject empty system messages.
        resolvedSlots.removeAll { $0.tokenCount == 0 }

        // 5. Build the per-slot breakdown after all clamping.
        var budgetBreakdown: [String: Int] = [:]
        for slot in resolvedSlots { budgetBreakdown[slot.id] = slot.tokenCount }

        // 6. Calculate total slot tokens and remaining budget for messages.
        let totalSlotTokens = resolvedSlots.reduce(0) { $0 + $1.tokenCount }
        let availableForMessages = max(0, contextSize - totalSlotTokens - responseBuffer)

        // 4. Trim messages to fit remaining budget (newest first, like ContextWindowManager).
        // totalTokens comes free from the trim loop — no second pass needed.
        let (trimmedMessages, messageTokens) = trimMessagesToFit(messages, budget: availableForMessages, tokenizer: tok)
        budgetBreakdown["history"] = messageTokens

        // 5. Sort resolved slots by position for final ordering.
        // Tiebreak by input-array index to keep declaration order stable for equal positions.
        let mc = trimmedMessages.count
        let sortedSlots = resolvedSlots
            .enumerated()
            .sorted {
                let li = $0.element.position.sortIndex(messageCount: mc)
                let ri = $1.element.position.sortIndex(messageCount: mc)
                return li == ri ? $0.offset < $1.offset : li < ri
            }
            .map(\.element)

        // 6. Build the final message list, inserting history-positioned slots
        let finalMessages = insertSlotsIntoHistory(slots: sortedSlots, messages: trimmedMessages)

        return AssembledPrompt(
            orderedSlots: sortedSlots,
            messages: finalMessages,
            totalTokens: totalSlotTokens + messageTokens,
            budgetBreakdown: budgetBreakdown
        )
    }

    // MARK: - Role-aware budget helpers

    // The role-aware allocator is *drop-only*: it cannot truncate content at
    // an arbitrary token boundary (`TokenizerProvider` exposes counting, not
    // tokenization with byte offsets), so any slot whose token cost would
    // exceed its allowance is dropped wholesale. This keeps `tokenCount`,
    // `budgetBreakdown`, and the actual prompt content consistent — accounting
    // never undercounts what the model receives. Per-slot truncation lives at
    // the caller's level via ``PromptSlot/tokenBudget``, which is applied
    // before role-aware trimming kicks in.

    /// Drops slots whose role-cap allowance is insufficient. Slots are admitted
    /// in input-array order; once a role's remaining cap can no longer cover a
    /// slot's full token cost, that slot is dropped entirely. Slots without a
    /// role cap are returned unchanged. The system role ignores caps — `.system`
    /// content is never dropped by policy.
    private static func applyRoleCaps(
        to slots: [ResolvedSlot],
        policy: BudgetPolicy
    ) -> [ResolvedSlot] {
        var remaining: [PromptSlotRole: Int] = [:]
        return slots.compactMap { slot in
            if case .system = slot.role { return slot }
            guard let cap = policy.cap(for: slot.role) else { return slot }
            let left = remaining[slot.role] ?? cap
            guard slot.tokenCount <= left else { return nil }
            remaining[slot.role] = left - slot.tokenCount
            return slot
        }
    }

    /// Drops slots in priority order so the combined token cost fits within
    /// `slotBudget`. Lowest-priority roles are dropped first; within a role,
    /// later slots in the input array are dropped before earlier ones (so the
    /// first slot in a role keeps its content if any slot in the role survives).
    /// `.system` slots are never dropped.
    private static func applyRolePriorityTrimming(
        to slots: [ResolvedSlot],
        slotBudget: Int,
        policy: BudgetPolicy
    ) -> [ResolvedSlot] {
        var current = slots.reduce(0) { $0 + $1.tokenCount }
        guard current > slotBudget else { return slots }

        // Indices ordered for dropping: lowest priority first; within the same
        // priority, later input order first. .system is excluded entirely so
        // it can never be dropped even when the budget is impossible.
        let dropOrder: [Int] = slots.indices
            .filter { idx in
                if case .system = slots[idx].role { return false }
                return true
            }
            .sorted { lhs, rhs in
                let lp = policy.priority(for: slots[lhs].role)
                let rp = policy.priority(for: slots[rhs].role)
                return lp == rp ? lhs > rhs : lp > rp
            }

        var dropped: Set<Int> = []
        for idx in dropOrder {
            if current <= slotBudget { break }
            dropped.insert(idx)
            current -= slots[idx].tokenCount
        }
        return slots.enumerated().compactMap { dropped.contains($0.offset) ? nil : $0.element }
    }

    // MARK: - Private Helpers

    /// Trims messages to fit within the given token budget.
    /// Walks backward from the newest message. When `budget <= 0`, it prefers keeping
    /// the most recent user message, or falls back to the newest message if no user
    /// message exists. Returns both the trimmed messages and their total token count,
    /// so the caller does not need a second pass to compute the budget breakdown.
    private static func trimMessagesToFit(
        _ messages: [ChatMessageRecord],
        budget: Int,
        tokenizer: TokenizerProvider
    ) -> (messages: [ChatMessageRecord], totalTokens: Int) {
        guard !messages.isEmpty else { return ([], 0) }

        if budget <= 0 {
            if let lastUser = messages.last(where: { $0.role == .user }) {
                return ([lastUser], tokenizer.tokenCount(lastUser.content))
            }
            let last = messages.suffix(1)
            return (Array(last), last.reduce(0) { $0 + tokenizer.tokenCount($1.content) })
        }

        var kept: [ChatMessageRecord] = []
        var usedTokens = 0

        for message in messages.reversed() {
            let count = tokenizer.tokenCount(message.content)
            if usedTokens + count > budget && !kept.isEmpty { break }
            kept.append(message)
            usedTokens += count
        }

        return (kept.reversed(), usedTokens)
    }

    /// Inserts slots into the message history based on their position.
    ///
    /// Top slots (``PromptSlotPosition/systemPreamble`` and ``PromptSlotPosition/contextSetup``)
    /// are prepended as system messages before the history stream.
    /// History-positioned slots are inserted at `max(0, count - depth)` from the bottom,
    /// using the original message count so insertion order does not shift targets.
    private static func insertSlotsIntoHistory(
        slots: [ResolvedSlot],
        messages: [ChatMessageRecord]
    ) -> [(role: String, content: String)] {
        let topSlots = slots.filter { $0.position.isTopSlot }
        let historySlots = slots.filter { !$0.position.isTopSlot }

        var result: [(role: String, content: String)] = topSlots.map { (role: "system", content: $0.content) }
        var messageTuples = messages.map { (role: $0.role.rawValue, content: $0.content) }

        // Process lowest depth first (bottom-to-top) using the original message count
        // for all index calculations, so that earlier inserts don't perturb the targets
        // of later ones. For slots at the same depth, reverse input order before inserting
        // so that the final array reflects the original input order.
        let originalCount = messageTuples.count
        let sorted = historySlots
            .enumerated()
            .sorted { lhs, rhs in
                let ld = lhs.element.position.insertionDepth(messageCount: originalCount)
                let rd = rhs.element.position.insertionDepth(messageCount: originalCount)
                // Ascending depth (bottom first); within same depth, reverse offset so
                // final order matches input order after same-index inserts.
                return ld == rd ? lhs.offset > rhs.offset : ld < rd
            }
            .map(\.element)
        for slot in sorted {
            let depth = slot.position.insertionDepth(messageCount: originalCount)
            let idx = max(0, originalCount - depth)
            messageTuples.insert((role: "system", content: slot.content), at: idx)
        }

        result.append(contentsOf: messageTuples)
        return result
    }
}
