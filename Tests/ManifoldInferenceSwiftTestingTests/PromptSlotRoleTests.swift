import Testing
import Foundation
@testable import ManifoldInference

/// Deterministic tokenizer: at least 1 token, otherwise 1 token per character
/// (`max(1, text.count)` so empty strings still cost a token).
private struct CharTokenizer: TokenizerProvider {
    func tokenCount(_ text: String) -> Int { max(1, text.count) }
}

@Suite("PromptSlotRole + BudgetPolicy")
struct PromptSlotRoleTests {

    // MARK: - PromptSlotRole.Codable

    @Test func test_codable_roundTrip_allCases() throws {
        let cases: [PromptSlotRole] = [
            .system, .characterContext, .retrieval, .archival,
            .userInstruction, .conversationHistory, .custom("memory"),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for role in cases {
            let data = try encoder.encode(role)
            let decoded = try decoder.decode(PromptSlotRole.self, from: data)
            #expect(decoded == role)
        }
    }

    @Test func test_decode_unknownType_throws() {
        let json = #"{"type":"bogus"}"#
        let data = Data(json.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PromptSlotRole.self, from: data)
        }
    }

    // MARK: - BudgetPolicy default ordering

    @Test func test_defaultPolicy_orderingMatchesIssue110() {
        let p = BudgetPolicy.default
        // Lower number = higher priority (kept first).
        #expect(p.priority(for: .system) <
                p.priority(for: .characterContext))
        #expect(p.priority(for: .characterContext) <
                p.priority(for: .retrieval))
        #expect(p.priority(for: .retrieval) <
                p.priority(for: .archival))
        #expect(p.priority(for: .archival) <
                p.priority(for: .userInstruction))
        #expect(p.priority(for: .userInstruction) <
                p.priority(for: .conversationHistory))
    }

    @Test func test_defaultPolicy_customRoleHasLowestPriority() {
        let p = BudgetPolicy.default
        #expect(p.priority(for: .custom("anything")) >
                p.priority(for: .conversationHistory))
    }

    // MARK: - PromptSlot defaults

    @Test func test_promptSlot_defaultsToUserInstruction() {
        let slot = PromptSlot(id: "x", content: "hi", label: "X")
        #expect(slot.role == .userInstruction)
    }

    @Test func test_promptSlot_acceptsExplicitRole() {
        let slot = PromptSlot(id: "char", content: "Persona", role: .characterContext, label: "Char")
        #expect(slot.role == .characterContext)
    }

    // MARK: - Per-role caps

    @Test func test_assembler_roleCap_dropsSlotsThatDoNotFitWithinCap() {
        // Two retrieval slots totalling 30 tokens, capped at 20. The allocator
        // is drop-only (it cannot truncate content at a token boundary), so the
        // first slot is admitted in full (15) and the second is dropped because
        // its 15-token cost exceeds the 5-token remaining cap.
        let slots = [
            PromptSlot(id: "r1", content: "aaaaaaaaaaaaaaa", role: .retrieval, label: "R1"), // 15
            PromptSlot(id: "r2", content: "bbbbbbbbbbbbbbb", role: .retrieval, label: "R2"), // 15
        ]
        var policy = BudgetPolicy.default
        policy.caps[.retrieval] = 20
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0,
            tokenizer: CharTokenizer(), policy: policy
        )
        #expect(result.budgetBreakdown["r1"] == 15)
        #expect(result.budgetBreakdown["r2"] == nil) // dropped — exceeds remaining cap
        // The dropped slot must also be absent from the assembled prompt content
        // so token accounting matches what the model receives.
        #expect(result.orderedSlots.contains(where: { $0.id == "r1" }))
        #expect(!result.orderedSlots.contains(where: { $0.id == "r2" }))
    }

    @Test func test_assembler_roleCap_admitsSlotThatFitsExactly() {
        // A single retrieval slot whose token cost equals the cap is admitted.
        let slots = [
            PromptSlot(id: "r", content: String(repeating: "a", count: 20),
                       role: .retrieval, label: "R"), // 20
        ]
        var policy = BudgetPolicy.default
        policy.caps[.retrieval] = 20
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0,
            tokenizer: CharTokenizer(), policy: policy
        )
        #expect(result.budgetBreakdown["r"] == 20)
    }

    @Test func test_assembler_systemRole_ignoresCapAndPriorityTrim() {
        // Even if the caller sets a cap on .system, the assembler ignores it.
        // The system slot is also never trimmed when the budget overflows.
        let slots = [
            PromptSlot(id: "ret", content: String(repeating: "r", count: 100),
                       role: .retrieval, label: "Ret"),
        ]
        var policy = BudgetPolicy.default
        policy.caps[.system] = 1
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: "Be helpful",
            contextSize: 50, responseBuffer: 0,
            tokenizer: CharTokenizer(), policy: policy
        )
        // System ("Be helpful" = 10 chars/tokens) survives intact even though
        // the slotBudget is 50 and the total content is 110.
        #expect(result.budgetBreakdown["system"] == 10)
    }

    // MARK: - Priority-driven trimming

    @Test func test_assembler_priorityTrim_dropsLowestRoleFirst() {
        // slotBudget = 30. Total content = 60.
        // Default priority: characterContext (kept) > retrieval > userInstruction > custom (dropped first).
        let slots = [
            PromptSlot(id: "char", content: String(repeating: "c", count: 20),
                       role: .characterContext, label: "Char"),
            PromptSlot(id: "ret", content: String(repeating: "r", count: 20),
                       role: .retrieval, label: "Ret"),
            PromptSlot(id: "cust", content: String(repeating: "x", count: 20),
                       role: .custom("notes"), label: "Custom"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: nil,
            contextSize: 30, responseBuffer: 0,
            tokenizer: CharTokenizer(), policy: .default
        )
        // Drop-only semantics: `cust` (lowest) goes first (60 → 40), still over by 10.
        // The allocator cannot truncate `ret` mid-content, so it drops `ret`
        // wholesale (40 → 20). Character context survives intact.
        #expect(result.budgetBreakdown["char"] == 20)
        #expect(result.budgetBreakdown["ret"] == nil) // dropped — over-budget after cust drop
        #expect(result.budgetBreakdown["cust"] == nil) // dropped — lowest priority
        // The dropped slots must also be absent from the assembled prompt content.
        #expect(result.orderedSlots.map(\.id) == ["char"])
    }

    @Test func test_assembler_priorityTrim_zeroBudget_dropsAllNonSystemSlots() {
        // contextSize == responseBuffer means slotBudget = 0. Every non-system
        // slot is dropped, but the system slot is preserved by policy.
        let slots = [
            PromptSlot(id: "ret", content: String(repeating: "r", count: 20),
                       role: .retrieval, label: "Ret"),
            PromptSlot(id: "char", content: String(repeating: "c", count: 20),
                       role: .characterContext, label: "Char"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: "sys",
            contextSize: 100, responseBuffer: 100, // slotBudget = 0
            tokenizer: CharTokenizer(), policy: .default
        )
        #expect(result.budgetBreakdown["system"] == 3) // "sys" survives
        #expect(result.budgetBreakdown["ret"] == nil)
        #expect(result.budgetBreakdown["char"] == nil)
        #expect(result.orderedSlots.map(\.id) == ["system"])
    }

    @Test func test_assembler_priorityTrim_systemAlwaysSurvives() {
        // Even with an impossible budget, the system slot is never trimmed.
        // Other slots are trimmed/dropped to make as much room as possible.
        let slots = [
            PromptSlot(id: "ret", content: String(repeating: "r", count: 50),
                       role: .retrieval, label: "Ret"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: String(repeating: "s", count: 40),
            contextSize: 30, responseBuffer: 0,
            tokenizer: CharTokenizer(), policy: .default
        )
        #expect(result.budgetBreakdown["system"] == 40)
        #expect(result.budgetBreakdown["ret"] == nil) // dropped to fit
    }

    @Test func test_assembler_priorityTrim_customRolePolicyOverride() {
        // Caller can promote a custom role above conversationHistory.
        var policy = BudgetPolicy.default
        let custom = PromptSlotRole.custom("memory")
        policy.priorities[custom] = 1 // higher priority than character context, etc.

        let slots = [
            // Same priority numerically (1) means input order is the tiebreaker
            // for trimming order — second one trims first.
            PromptSlot(id: "memo", content: String(repeating: "m", count: 20),
                       role: custom, label: "Memo"),
            PromptSlot(id: "char", content: String(repeating: "c", count: 20),
                       role: .characterContext, label: "Char"),
            PromptSlot(id: "ret", content: String(repeating: "r", count: 20),
                       role: .retrieval, label: "Ret"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: nil,
            contextSize: 40, responseBuffer: 0,
            tokenizer: CharTokenizer(), policy: policy
        )
        // ret (lowest) is dropped first; we still need 0 more from the 60 → 40
        // budget cut, so memo and char survive intact.
        #expect(result.budgetBreakdown["memo"] == 20)
        #expect(result.budgetBreakdown["char"] == 20)
        #expect(result.budgetBreakdown["ret"] == nil)
    }

    // MARK: - Backwards compatibility

    @Test func test_assembler_noPolicyOverride_preservesPreRoleBehavior() {
        // Without role caps and within budget, the result is identical to the
        // pre-role behaviour — no slot is trimmed by policy.
        let slots = [
            PromptSlot(id: "a", content: "aaaa", label: "A"),
            PromptSlot(id: "b", content: "bb", label: "B"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: "sys",
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        #expect(result.budgetBreakdown["a"] == 4)
        #expect(result.budgetBreakdown["b"] == 2)
        #expect(result.budgetBreakdown["system"] == 3)
    }
}
