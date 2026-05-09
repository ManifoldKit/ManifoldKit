import Foundation

/// Describes where a ``PromptSlot`` appears in the assembled prompt.
///
/// Use semantic positions rather than raw depth integers to make slot placement
/// intent explicit and independent of the history length at assembly time.
public enum PromptSlotPosition: Hashable, Sendable {
    /// Before all other content — the very top of the prompt.
    case systemPreamble
    /// After the system preamble, before conversation history.
    case contextSetup
    /// Injected `n` messages from the bottom of the trimmed history.
    /// `n` must be >= 0; `atDepth(0)` is equivalent to ``bottomOfHistory``.
    case atDepth(Int)
    /// Just above the oldest visible message — the top of history.
    case topOfHistory
    /// Just above the most recent user message — the bottom of history.
    case bottomOfHistory
    /// Inserted after all history messages, immediately before the model turn.
    case inline
}

extension PromptSlotPosition: Codable {
    private enum CodingKeys: String, CodingKey { case type, depth }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(String.self, forKey: .type)
        switch t {
        case "systemPreamble":  self = .systemPreamble
        case "contextSetup":    self = .contextSetup
        case "atDepth":
            let depth = try c.decode(Int.self, forKey: .depth)
            guard depth >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .depth, in: c,
                    debugDescription: "PromptSlotPosition.atDepth depth must be >= 0, got \(depth)"
                )
            }
            self = .atDepth(depth)
        case "topOfHistory":    self = .topOfHistory
        case "bottomOfHistory": self = .bottomOfHistory
        case "inline":          self = .inline
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown PromptSlotPosition type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemPreamble:   try c.encode("systemPreamble", forKey: .type)
        case .contextSetup:     try c.encode("contextSetup", forKey: .type)
        case .atDepth(let n):   try c.encode("atDepth", forKey: .type); try c.encode(n, forKey: .depth)
        case .topOfHistory:     try c.encode("topOfHistory", forKey: .type)
        case .bottomOfHistory:  try c.encode("bottomOfHistory", forKey: .type)
        case .inline:           try c.encode("inline", forKey: .type)
        }
    }
}

extension PromptSlotPosition {
    /// Whether this position places the slot before the message history stream.
    var isTopSlot: Bool {
        if case .systemPreamble = self { return true }
        if case .contextSetup = self { return true }
        return false
    }

    /// A stable sort key that reflects the order slots appear in the assembled prompt
    /// (top to bottom; low index = earlier in prompt).
    ///
    /// systemPreamble (0) and contextSetup (1) come first.
    /// topOfHistory (2) is the highest history position.
    /// atDepth(n): larger n means higher placement (further from latest turn), so smaller index.
    /// bottomOfHistory sits just above the last message; inline follows all messages.
    ///
    /// Widened to `public` in Phase 1.2 sub-step 2 so that `PromptContextPipeline`
    /// (in `ManifoldCore`) can use this comparator to merge `[PromptSlot]` from
    /// multiple `PromptContextProvider`s.
    public func sortIndex(messageCount: Int) -> Int {
        switch self {
        case .systemPreamble:   return 0
        case .contextSetup:     return 1
        case .topOfHistory:     return 2
        case .atDepth(let n):   return 2 + (messageCount - n)
        case .bottomOfHistory:  return 2 + messageCount
        case .inline:           return 3 + messageCount
        }
    }

    /// The number of messages from the bottom of history at which to insert the slot.
    ///
    /// Pass the original (pre-insertion) message count so that insertion order
    /// does not shift subsequent targets.
    func insertionDepth(messageCount: Int) -> Int {
        switch self {
        case .topOfHistory:             return messageCount
        case .atDepth(let n):           return n
        case .bottomOfHistory, .inline: return 0
        default:                        return 0
        }
    }

    /// Short human-readable label suitable for inspector UI.
    public var displayName: String {
        switch self {
        case .systemPreamble:   return "system preamble"
        case .contextSetup:     return "context setup"
        case .atDepth(let n):   return "depth \(n)"
        case .topOfHistory:     return "top of history"
        case .bottomOfHistory:  return "bottom of history"
        case .inline:           return "inline"
        }
    }
}

/// The semantic source of a ``PromptSlot``.
///
/// Roles let the assembler apply per-source priority and caps when the budget
/// is tight: e.g. trim retrieval before character context, and trim custom
/// slots before either. See ``BudgetPolicy`` for the trimming order.
public enum PromptSlotRole: Hashable, Sendable {
    /// Core system prompt content. Highest priority — never trimmed by the
    /// role-aware allocator.
    case system
    /// Persona / character definition.
    case characterContext
    /// Keyword or semantic retrieval results (e.g. RAG, graph retrieval).
    case retrieval
    /// Long-term archival memory retrievals.
    case archival
    /// Lorebook / world info / instructions injected by user configuration.
    case userInstruction
    /// Conversation history slot (rare — history is normally handled separately).
    case conversationHistory
    /// App-defined role with a string discriminator. Treated as the lowest
    /// priority by default (``BudgetPolicy/customPriority``), unless callers
    /// override the policy.
    case custom(String)
}

extension PromptSlotRole: Codable {
    private enum CodingKeys: String, CodingKey { case type, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(String.self, forKey: .type)
        switch t {
        case "system":              self = .system
        case "characterContext":    self = .characterContext
        case "retrieval":           self = .retrieval
        case "archival":            self = .archival
        case "userInstruction":     self = .userInstruction
        case "conversationHistory": self = .conversationHistory
        case "custom":
            let name = try c.decode(String.self, forKey: .name)
            self = .custom(name)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown PromptSlotRole type \"\(t)\""
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system:              try c.encode("system", forKey: .type)
        case .characterContext:    try c.encode("characterContext", forKey: .type)
        case .retrieval:           try c.encode("retrieval", forKey: .type)
        case .archival:            try c.encode("archival", forKey: .type)
        case .userInstruction:     try c.encode("userInstruction", forKey: .type)
        case .conversationHistory: try c.encode("conversationHistory", forKey: .type)
        case .custom(let name):
            try c.encode("custom", forKey: .type)
            try c.encode(name, forKey: .name)
        }
    }
}

extension PromptSlotRole {
    /// Short human-readable label suitable for prompt inspector UI.
    public var displayName: String {
        switch self {
        case .system:              return "system"
        case .characterContext:    return "character context"
        case .retrieval:           return "retrieval"
        case .archival:            return "archival"
        case .userInstruction:     return "user instruction"
        case .conversationHistory: return "conversation history"
        case .custom(let name):    return "custom (\(name))"
        }
    }
}

/// Policy describing how the assembler allocates the per-slot budget across
/// ``PromptSlotRole``s when the total content exceeds the context window.
///
/// Slots whose role has a higher priority (lower number) are kept first; slots
/// in lower-priority roles are trimmed (or dropped) first. Per-role caps apply
/// before priority trimming — a role-specific cap clamps the combined token
/// usage of all slots in that role.
///
/// The default policy uses the order specified in #110:
/// `.system` > `.characterContext` > `.retrieval` > `.archival` >
/// `.userInstruction` > `.conversationHistory`.
public struct BudgetPolicy: Sendable {
    /// Priority for each known role. Lower number = higher priority (kept first).
    /// Roles missing from the dictionary use ``customPriority``.
    public var priorities: [PromptSlotRole: Int]

    /// Optional per-role cap on the combined token cost of all slots in that
    /// role. `nil` (or missing key) means no role-level cap; the slot's own
    /// `tokenBudget` is still honored.
    public var caps: [PromptSlotRole: Int]

    /// Priority assigned to ``PromptSlotRole/custom(_:)`` and any role missing
    /// from ``priorities``. Defaults to a value lower than every built-in role,
    /// so custom slots are trimmed first.
    public var customPriority: Int

    public init(
        priorities: [PromptSlotRole: Int] = BudgetPolicy.defaultPriorities,
        caps: [PromptSlotRole: Int] = [:],
        customPriority: Int = 1000
    ) {
        self.priorities = priorities
        self.caps = caps
        self.customPriority = customPriority
    }

    /// Default priority order from issue #110:
    /// `.system` > `.characterContext` > `.retrieval` > `.archival` >
    /// `.userInstruction` > `.conversationHistory`.
    public static let defaultPriorities: [PromptSlotRole: Int] = [
        .system:              0,
        .characterContext:    1,
        .retrieval:           2,
        .archival:            3,
        .userInstruction:     4,
        .conversationHistory: 5,
    ]

    /// The default policy: priorities from #110, no role caps, custom slots
    /// trimmed first.
    public static let `default` = BudgetPolicy()

    /// Resolves the priority for a role, falling back to ``customPriority`` for
    /// ``PromptSlotRole/custom(_:)`` and any role missing from ``priorities``.
    public func priority(for role: PromptSlotRole) -> Int {
        priorities[role] ?? customPriority
    }

    /// Resolves the optional per-role cap. `nil` means no cap.
    public func cap(for role: PromptSlotRole) -> Int? {
        caps[role]
    }
}

/// A named slot in the prompt assembly pipeline.
///
/// Each slot carries content that occupies part of the context window budget.
/// Slots are placed according to their ``position``; slots with the same
/// effective position retain their input-array order. The slot's ``role``
/// determines its priority in budget allocation — see ``BudgetPolicy``.
///
/// Use ``PromptAssembler/assemble(slots:messages:systemPrompt:contextSize:responseBuffer:tokenizer:policy:)``
/// to resolve slots and history into a final ``AssembledPrompt``.
public struct PromptSlot: Identifiable, Sendable {
    /// Unique identifier for this slot (e.g. "system", "charDef", "lorebook", "authorsNote").
    public let id: String

    /// The text content of this slot.
    public var content: String

    /// Where this slot appears in the assembled prompt.
    public var position: PromptSlotPosition

    /// The semantic source of this slot. Drives per-role priority and caps in
    /// the budget allocator. Defaults to ``PromptSlotRole/userInstruction`` so
    /// that pre-#110 callers (no explicit role) preserve existing behavior:
    /// no role-cap clamping, and trimmed before history but after retrieval
    /// and character context.
    public var role: PromptSlotRole

    /// Maximum token budget for this slot. `nil` means the slot uses as many
    /// tokens as its content requires (no cap).
    public var tokenBudget: Int?

    /// Whether this slot is active. Disabled slots are skipped during assembly.
    public var isEnabled: Bool

    /// Human-readable display name for prompt inspector UI.
    public var label: String

    public init(
        id: String,
        content: String,
        position: PromptSlotPosition = .contextSetup,
        role: PromptSlotRole = .userInstruction,
        tokenBudget: Int? = nil,
        isEnabled: Bool = true,
        label: String
    ) {
        if case .atDepth(let n) = position {
            precondition(n >= 0, "PromptSlotPosition.atDepth depth must be >= 0; got \(n)")
        }
        self.id = id
        self.content = content
        self.position = position
        self.role = role
        self.tokenBudget = tokenBudget
        self.isEnabled = isEnabled
        self.label = label
    }
}

/// A slot whose token cost has been calculated and finalized.
public struct ResolvedSlot: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let content: String
    public let tokenCount: Int
    public let position: PromptSlotPosition
    public let role: PromptSlotRole

    public init(
        id: String,
        label: String,
        content: String,
        tokenCount: Int,
        position: PromptSlotPosition,
        role: PromptSlotRole = .userInstruction
    ) {
        self.id = id
        self.label = label
        self.content = content
        self.tokenCount = tokenCount
        self.position = position
        self.role = role
    }
}

/// The output of ``PromptAssembler/assemble(slots:messages:systemPrompt:contextSize:responseBuffer:tokenizer:policy:)``.
public struct AssembledPrompt: Sendable {
    /// All resolved slots in their final order (position-sorted).
    public let orderedSlots: [ResolvedSlot]

    /// Trimmed conversation history as (role, content) pairs in chronological order.
    public let messages: [(role: String, content: String)]

    /// Total tokens consumed by slots + messages.
    public let totalTokens: Int

    /// Per-slot token usage keyed by slot id.
    public let budgetBreakdown: [String: Int]

    public init(
        orderedSlots: [ResolvedSlot],
        messages: [(role: String, content: String)],
        totalTokens: Int,
        budgetBreakdown: [String: Int]
    ) {
        self.orderedSlots = orderedSlots
        self.messages = messages
        self.totalTokens = totalTokens
        self.budgetBreakdown = budgetBreakdown
    }
}
