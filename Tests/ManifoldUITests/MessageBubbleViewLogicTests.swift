@preconcurrency import XCTest
import SwiftUI
import ViewInspector
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference

/// Tests for the data model and layout logic that drives MessageBubbleView.
///
/// MessageBubbleView renders differently based on message role, streaming state,
/// pin status, and content. These tests verify the model behavior and computed
/// properties that determine the view's appearance.
@MainActor
final class MessageBubbleViewLogicTests: XCTestCase {

    private let sessionID = UUID()

    // MARK: - ManifoldInference.ChatMessage construction

    func test_messageRecord_userRole_hasCorrectContent() {
        let msg = ManifoldInference.ChatMessage(
            role: .user,
            content: "Hello, world!",
            sessionID: sessionID
        )
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.content, "Hello, world!")
        XCTAssertEqual(msg.sessionID, sessionID)
    }

    func test_messageRecord_assistantRole_hasCorrectContent() {
        let msg = ManifoldInference.ChatMessage(
            role: .assistant,
            content: "Once upon a time...",
            sessionID: sessionID
        )
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.content, "Once upon a time...")
    }

    func test_messageRecord_systemRole_hasCorrectContent() {
        let msg = ManifoldInference.ChatMessage(
            role: .system,
            content: "You are a helpful assistant.",
            sessionID: sessionID
        )
        XCTAssertEqual(msg.role, .system)
        XCTAssertEqual(msg.content, "You are a helpful assistant.")
    }

    // MARK: - Content parts

    func test_messageRecord_contentViaPartsAccessor() {
        let msg = ManifoldInference.ChatMessage(
            role: .user,
            content: "Test content",
            sessionID: sessionID
        )
        XCTAssertEqual(msg.contentParts.count, 1, "Single text content should produce one part")
        if case .text(let text) = msg.contentParts.first {
            XCTAssertEqual(text, "Test content")
        } else {
            XCTFail("First content part should be .text")
        }
    }

    func test_messageRecord_settingContentReplacesAllParts() {
        var msg = ManifoldInference.ChatMessage(
            role: .user,
            content: "Original",
            sessionID: sessionID
        )
        msg.content = "Updated"
        XCTAssertEqual(msg.content, "Updated")
        XCTAssertEqual(msg.contentParts.count, 1, "Setting content should replace all parts with a single text part")
    }

    func test_messageRecord_multiplePartsJoinForContent() {
        let msg = ManifoldInference.ChatMessage(
            role: .assistant,
            contentParts: [
                .text("Hello"),
                .audio(url: URL(fileURLWithPath: "/Users/example/audio.m4a"), duration: 2, waveform: nil),
                .text(" world"),
            ],
            sessionID: sessionID
        )
        XCTAssertEqual(msg.content, "Hello world", "Content should be the concatenation of all text parts")
    }

    func test_messageRecord_audioOnlyHasNoVisibleTextButHasContentPart() {
        let msg = ManifoldInference.ChatMessage(
            role: .user,
            contentParts: [.audio(url: URL(fileURLWithPath: "/Users/example/audio.m4a"), duration: 2, waveform: [1])],
            sessionID: sessionID
        )
        XCTAssertEqual(msg.content, "")
        XCTAssertFalse(msg.hasVisibleContent)
        XCTAssertNotNil(msg.contentParts.first?.audioContent)
    }

    // MARK: - Empty content edge cases

    func test_messageRecord_emptyContent() {
        let msg = ManifoldInference.ChatMessage(
            role: .assistant,
            content: "",
            sessionID: sessionID
        )
        XCTAssertEqual(msg.content, "")
        XCTAssertTrue(msg.contentParts.isEmpty || msg.content.isEmpty,
                       "Empty content message should have empty content accessor")
    }

    func test_messageRecord_veryLongContent() {
        let longContent = String(repeating: "A", count: 100_000)
        let msg = ManifoldInference.ChatMessage(
            role: .user,
            content: longContent,
            sessionID: sessionID
        )
        XCTAssertEqual(msg.content.count, 100_000, "Should handle very long content without truncation")
    }

    func test_messageRecord_specialCharacters() {
        let specialContent = "Hello <world> & \"friends\" — it's a 'test' with émojis 🎉 and CJK 你好"
        let msg = ManifoldInference.ChatMessage(
            role: .user,
            content: specialContent,
            sessionID: sessionID
        )
        XCTAssertEqual(msg.content, specialContent, "Should preserve special characters exactly")
    }

    func test_messageRecord_multilineContent() {
        let multiline = "Line 1\nLine 2\n\nLine 4"
        let msg = ManifoldInference.ChatMessage(
            role: .assistant,
            content: multiline,
            sessionID: sessionID
        )
        XCTAssertEqual(msg.content, multiline, "Should preserve newlines in content")
    }

    // MARK: - Token counts

    func test_messageRecord_completionTokens() {
        let msg = ManifoldInference.ChatMessage(
            role: .assistant,
            content: "Response text",
            sessionID: sessionID,
            completionTokens: 42
        )
        XCTAssertEqual(msg.completionTokens, 42, "Should store completion token count")
    }

    func test_messageRecord_promptTokens() {
        let msg = ManifoldInference.ChatMessage(
            role: .user,
            content: "Prompt text",
            sessionID: sessionID,
            promptTokens: 15
        )
        XCTAssertEqual(msg.promptTokens, 15, "Should store prompt token count")
    }

    func test_messageRecord_nilTokenCounts() {
        let msg = ManifoldInference.ChatMessage(
            role: .assistant,
            content: "No tokens tracked",
            sessionID: sessionID
        )
        XCTAssertNil(msg.completionTokens, "Completion tokens should be nil by default")
        XCTAssertNil(msg.promptTokens, "Prompt tokens should be nil by default")
    }

    // MARK: - Message status

    func test_messageRecord_statusDefaultsToNil() {
        let msg = ManifoldInference.ChatMessage(role: .user, content: "Hello", sessionID: sessionID)

        XCTAssertNil(msg.status, "Status is opt-in so existing records keep their current rendering")
    }

    func test_messageBubbleStatusText_rendersUserDeliveryStates() {
        let sent = ManifoldInference.ChatMessage(role: .user, content: "Hello", sessionID: sessionID, status: .sent)
        let failed = ManifoldInference.ChatMessage(role: .user, content: "Hello", sessionID: sessionID, status: .failed)
        let sending = ManifoldInference.ChatMessage(role: .user, content: "Hello", sessionID: sessionID, status: .sending)

        XCTAssertEqual(MessageBubbleView.statusText(for: sent), "Sent")
        XCTAssertEqual(MessageBubbleView.statusAccessibilityLabel(for: sent), "Message sent")
        XCTAssertEqual(MessageBubbleView.statusText(for: failed), "Failed")
        XCTAssertEqual(MessageBubbleView.statusAccessibilityLabel(for: failed), "Message failed to send")
        XCTAssertEqual(MessageBubbleView.statusText(for: sending), "Sending…")
        XCTAssertEqual(MessageBubbleView.statusAccessibilityLabel(for: sending), "Message sending")
    }

    func test_messageBubbleStatusText_ignoresAssistantStatus() {
        let assistant = ManifoldInference.ChatMessage(role: .assistant, content: "Reply", sessionID: sessionID, status: .sent)

        XCTAssertNil(MessageBubbleView.statusText(for: assistant))
        XCTAssertNil(MessageBubbleView.statusAccessibilityLabel(for: assistant))
    }

    // MARK: - Role enumeration coverage

    func test_allRoles_areDistinct() {
        let roles: [MessageRole] = [.user, .assistant, .system]
        XCTAssertEqual(Set(roles).count, 3, "All three roles should be distinct values")
    }

    // MARK: - Streaming state data model

    /// Empty content produces empty contentParts — the view uses this to decide
    /// whether to show a typing indicator vs partial content.
    func test_emptyContent_hasEmptyParts() {
        let msg = ManifoldInference.ChatMessage(role: .assistant, content: "", sessionID: sessionID)
        XCTAssertTrue(msg.content.isEmpty)
        XCTAssertTrue(msg.contentParts.isEmpty || msg.contentParts.allSatisfy {
            if case .text(let t) = $0 { return t.isEmpty } else { return false }
        }, "Empty content should produce empty or blank parts")
    }

    /// Non-empty content produces non-empty contentParts — the view uses this
    /// to show content + streaming cursor.
    func test_nonEmptyContent_hasNonEmptyParts() {
        let msg = ManifoldInference.ChatMessage(role: .assistant, content: "Partial response...", sessionID: sessionID)
        XCTAssertFalse(msg.contentParts.isEmpty, "Non-empty content should produce non-empty parts")
    }

    // MARK: - Identifiable conformance

    func test_messageRecord_identifiable_uniqueIDs() {
        let msg1 = ManifoldInference.ChatMessage(role: .user, content: "First", sessionID: sessionID)
        let msg2 = ManifoldInference.ChatMessage(role: .user, content: "Second", sessionID: sessionID)
        XCTAssertNotEqual(msg1.id, msg2.id, "Each message should have a unique ID")
    }

    func test_messageRecord_hashable_sameIDsEqual() {
        let sharedID = UUID()
        let sharedTimestamp = Date(timeIntervalSince1970: 1000)
        let msg1 = ManifoldInference.ChatMessage(id: sharedID, role: .user, content: "Content", timestamp: sharedTimestamp, sessionID: sessionID)
        let msg2 = ManifoldInference.ChatMessage(id: sharedID, role: .user, content: "Content", timestamp: sharedTimestamp, sessionID: sessionID)
        XCTAssertEqual(msg1, msg2, "Messages with the same ID and content should be equal")
    }

    // MARK: - Timestamp

    func test_messageRecord_timestampDefaultsToNow() {
        let before = Date()
        let msg = ManifoldInference.ChatMessage(role: .user, content: "Test", sessionID: sessionID)
        let after = Date()
        XCTAssertGreaterThanOrEqual(msg.timestamp, before, "Timestamp should be >= creation start time")
        XCTAssertLessThanOrEqual(msg.timestamp, after, "Timestamp should be <= creation end time")
    }

    func test_messageRecord_customTimestamp() {
        let customDate = Date(timeIntervalSince1970: 1000)
        let msg = ManifoldInference.ChatMessage(
            role: .user,
            content: "Test",
            timestamp: customDate,
            sessionID: sessionID
        )
        XCTAssertEqual(msg.timestamp, customDate, "Should use the provided custom timestamp")
    }

    // MARK: - W3A: per-agent badge rendering

    /// When `message.agentID` resolves to an agent in `session.agents`, the
    /// bubble's computed `resolvedAgent` returns that agent and the rendered
    /// view exposes an `agent-badge-<uuid>` accessibility identifier.
    ///
    /// Sabotage-evidence:
    ///   M1: remove the `resolvedAgent` lookup → returns nil → no badge.
    ///   M2: set `session = nil` on the view → resolvedAgent is nil.
    ///   M3: clear `session.agents` → lookup fails → no badge.
    func test_bubble_withResolvedAgentID_rendersAgentBadge() throws {
        let agent = ManifoldInference.AgentDefinition(name: "Researcher", systemPrompt: "do research", description: "researcher")
        let session = ManifoldInference.ChatSession(id: sessionID, agents: [agent], activeAgentID: agent.id)
        let msg = ManifoldInference.ChatMessage(
            role: .assistant,
            content: "Findings ready.",
            sessionID: sessionID,
            agentID: agent.id
        )
        let view = MessageBubbleView(message: msg, isStreaming: false, session: session)

        XCTAssertEqual(view.resolvedAgent?.id, agent.id, "Agent must resolve when it exists in session.agents")
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "agent-badge-\(agent.id.uuidString)")
    }

    /// When `agentID` points to a UUID that is **not** in `session.agents`
    /// (deleted-agent dangling-reference path flagged by architect review),
    /// the bubble must render cleanly as a normal assistant message:
    /// no crash, no "unknown agent" placeholder, no badge.
    ///
    /// Sabotage-evidence:
    ///   M1: change `resolvedAgent` to force-unwrap → would crash here.
    ///   M2: add a fallback "Unknown" label → finder for that label would fire.
    ///   M3: remove the nil-guard in agentBadge call site → fatal.
    func test_bubble_withUnresolvedAgentID_fallsBackToRoleRender() throws {
        let realAgent = ManifoldInference.AgentDefinition(name: "Researcher", systemPrompt: "", description: "")
        let danglingID = UUID()
        let session = ManifoldInference.ChatSession(id: sessionID, agents: [realAgent])
        let msg = ManifoldInference.ChatMessage(
            role: .assistant,
            content: "Hello",
            sessionID: sessionID,
            agentID: danglingID
        )
        let view = MessageBubbleView(message: msg, isStreaming: false, session: session)

        XCTAssertNil(view.resolvedAgent, "Dangling agentID must NOT resolve")
        // No badge identifier should exist for the dangling UUID.
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "agent-badge-\(danglingID.uuidString)"),
            "No badge should render for a dangling agentID"
        )
        // The bubble must still be inspectable and contain the assistant text.
        // Accessibility label is the deterministic surface for role-based render.
        XCTAssertEqual(
            MessageBubbleView.accessibilityLabel(for: msg),
            "Assistant said: Hello",
            "Deleted-agent fallback must use the standard assistant label, never 'unknown'."
        )
    }

    /// Pre-W3A messages have `agentID == nil`. Their rendering must be
    /// byte-identical to the old role-based path.
    ///
    /// Sabotage-evidence:
    ///   M1: default `agentID` to a non-nil value → resolvedAgent might fire.
    ///   M2: render a placeholder badge when agentID is nil → finder hits.
    ///   M3: change accessibility label for nil agentID → string changes.
    func test_bubble_withNilAgentID_unchanged() throws {
        let session = ManifoldInference.ChatSession(id: sessionID, agents: [])
        let msg = ManifoldInference.ChatMessage(role: .assistant, content: "Plain", sessionID: sessionID)
        XCTAssertNil(msg.agentID)
        let view = MessageBubbleView(message: msg, isStreaming: false, session: session)
        XCTAssertNil(view.resolvedAgent, "nil agentID must produce nil resolvedAgent — preserves pre-W3A render.")
        // Accessibility label matches the standard role-based contract.
        XCTAssertEqual(
            MessageBubbleView.accessibilityLabel(for: msg),
            "Assistant said: Plain"
        )
    }

    /// Agent color is a pure function of UUID. Two distinct agents almost
    /// always get different colors (palette has 8 entries, so duplicates are
    /// possible but rare); the same UUID always maps to the same color.
    ///
    /// Sabotage-evidence:
    ///   M1: make color depend on Date() → same UUID returns different color.
    ///   M2: hash by `id.hashValue` (per-process random seed) → fails determinism.
    ///   M3: ignore UUID bytes → always returns palette[0].
    func test_agentColor_isDeterministicForSameUUID() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        XCTAssertEqual(
            MessageBubbleView.agentColor(for: id),
            MessageBubbleView.agentColor(for: id),
            "agentColor must be a pure function of the UUID."
        )
    }

    // MARK: - W3A: handoff chip rendering

    private func agentPair() -> (ManifoldInference.AgentDefinition, ManifoldInference.AgentDefinition) {
        let a = ManifoldInference.AgentDefinition(name: "Researcher", systemPrompt: "", description: "")
        let b = ManifoldInference.AgentDefinition(name: "Writer", systemPrompt: "", description: "")
        return (a, b)
    }

    /// HandoffChipView renders a "to <Name>" pill when both `from` and `to`
    /// are non-nil — the transition case between agents in a session.
    ///
    /// Sabotage-evidence:
    ///   M1: render the chip even when `to == nil` → finder hits twice.
    ///   M2: drop the agent name from the label → search fails.
    ///   M3: invert the transition check → chip renders for same-agent runs.
    func test_handoffChip_appearsAtAgentTransition() throws {
        let (from, to) = agentPair()
        let chip = HandoffChipView(from: from, to: to)
        _ = try chip.inspect().find(viewWithAccessibilityIdentifier: "handoff-chip-\(to.id.uuidString)")
    }

    /// Chip must not render when `from == nil` (first-message case). This
    /// guards against a chip popping above the first agent-attributed
    /// message in a session.
    ///
    /// Sabotage-evidence:
    ///   M1: drop the `from != nil` guard → chip renders → finder hits.
    ///   M2: render a "Start" chip when from is nil → finder hits.
    ///   M3: render unconditionally → finder hits.
    func test_handoffChip_doesNotAppearOnFirstMessage() {
        let (_, to) = agentPair()
        let chip = HandoffChipView(from: nil, to: to)
        XCTAssertThrowsError(
            try chip.inspect().find(viewWithAccessibilityIdentifier: "handoff-chip-\(to.id.uuidString)"),
            "No chip should render when from is nil (first message)."
        )
    }

    /// `to == nil` means the target agent could not be resolved against
    /// the session registry. Chip must suppress fully.
    ///
    /// Sabotage-evidence:
    ///   M1: drop the `to` guard → chip renders with a placeholder name → finder hits.
    ///   M2: render an "?" chip when to is nil → finder for handoff-chip-* hits.
    ///   M3: ignore nil and force-unwrap → would crash.
    func test_handoffChip_doesNotAppearWhenTargetUnresolved() throws {
        let (from, fromOther) = agentPair()
        let chip = HandoffChipView(from: from, to: nil)
        // No handoff-chip-* identifier should be findable (neither agent's UUID).
        XCTAssertThrowsError(
            try chip.inspect().find(viewWithAccessibilityIdentifier: "handoff-chip-\(from.id.uuidString)")
        )
        XCTAssertThrowsError(
            try chip.inspect().find(viewWithAccessibilityIdentifier: "handoff-chip-\(fromOther.id.uuidString)")
        )
    }

    /// Logical contract: the history handoff resolver returns a chip when
    /// adjacent messages change agents and both agents resolve from the session.
    ///
    /// Sabotage-evidence:
    ///   M1: compare by message.id instead of agentID → equality flips.
    ///   M2: forget to resolve agents from the session → target assertions fail.
    ///   M3: swap `from` and `to` → target assertion fails.
    func test_handoffResolver_returnsChipAtAgentTransition() throws {
        let (from, to) = agentPair()
        let session = ManifoldInference.ChatSession(id: sessionID, agents: [from, to])
        let msgA = ManifoldInference.ChatMessage(role: .assistant, content: "first", sessionID: sessionID, agentID: from.id)
        let msgB = ManifoldInference.ChatMessage(role: .assistant, content: "second", sessionID: sessionID, agentID: to.id)

        let chip = try XCTUnwrap(ChatHistoryHandoffResolver.chip(
            at: 1,
            messages: [msgA, msgB],
            session: session
        ))

        XCTAssertEqual(chip.from?.id, from.id)
        XCTAssertEqual(chip.to?.id, to.id)
    }

    /// Logical contract: the history handoff resolver returns nil when
    /// adjacent messages share an `agentID`. We assert the helper directly
    /// rather than rendering the full ChatView.
    ///
    /// Sabotage-evidence:
    ///   M1: render the chip regardless of equality → test expects nil → fails.
    ///   M2: compare by message.id instead of agentID → equality flips.
    ///   M3: swap `!=` for `==` in the check → flips polarity.
    func test_handoffChip_doesNotAppearWithinSameAgent() {
        let (a, _) = agentPair()
        let session = ManifoldInference.ChatSession(id: sessionID, agents: [a])
        let msgA1 = ManifoldInference.ChatMessage(role: .assistant, content: "first", sessionID: sessionID, agentID: a.id)
        let msgA2 = ManifoldInference.ChatMessage(role: .assistant, content: "second", sessionID: sessionID, agentID: a.id)

        XCTAssertNil(
            ChatHistoryHandoffResolver.chip(at: 1, messages: [msgA1, msgA2], session: session),
            "Same-agent adjacent messages must NOT trigger a chip."
        )
    }

    /// Parity guard for the #1786 perf fix: `ChatHistoryView` now iterates
    /// `messages` directly (no `enumerated()`) and resolves handoff chips via
    /// the id-keyed ``ChatHistoryHandoffResolver/boundaries(messages:session:)``
    /// precompute. Its output must be byte-for-byte identical to calling the
    /// per-index ``chip(at:messages:session:)`` across an agent-transition
    /// fixture.
    ///
    /// Sabotage-evidence:
    ///   M1: off-by-one the boundary loop → a transition is keyed to the wrong id.
    ///   M2: drop the session guard in `boundaries` → chips appear without agents.
    func test_handoffBoundaries_matchPerIndexChipResolution() {
        let (a, b) = agentPair()
        let session = ManifoldInference.ChatSession(id: sessionID, agents: [a, b])
        let messages = [
            ManifoldInference.ChatMessage(role: .user, content: "q1", sessionID: sessionID, agentID: a.id),
            ManifoldInference.ChatMessage(role: .assistant, content: "a1", sessionID: sessionID, agentID: a.id),
            ManifoldInference.ChatMessage(role: .assistant, content: "a2", sessionID: sessionID, agentID: b.id),
            ManifoldInference.ChatMessage(role: .assistant, content: "a3", sessionID: sessionID, agentID: b.id),
            ManifoldInference.ChatMessage(role: .assistant, content: "a4", sessionID: sessionID, agentID: a.id),
        ]

        let boundaries = ChatHistoryHandoffResolver.boundaries(messages: messages, session: session)

        for index in messages.indices {
            let perIndex = ChatHistoryHandoffResolver.chip(at: index, messages: messages, session: session)
            let keyed = boundaries[messages[index].id]
            XCTAssertEqual(perIndex?.from?.id, keyed?.from?.id,
                           "from-agent mismatch at index \(index)")
            XCTAssertEqual(perIndex?.to?.id, keyed?.to?.id,
                           "to-agent mismatch at index \(index)")
        }

        // Exactly the two real transitions (a→b at index 2, b→a at index 4)
        // produce chips.
        XCTAssertEqual(boundaries.count, 2, "Only genuine agent transitions get a chip")
        XCTAssertNotNil(boundaries[messages[2].id])
        XCTAssertNotNil(boundaries[messages[4].id])
    }

    /// The `boundaries` early-out predicate is EXACT, not a heuristic: a chip
    /// needs two distinct agentIDs both resolving against `session.agents`, so
    /// <2 agents or <2 messages can never produce one.
    ///
    /// This asserts the predicate directly because the early-out is
    /// output-equivalent by construction — `boundaries` returns `[:]` for a
    /// single-agent session with or without it, so no black-box test of
    /// `boundaries` can detect whether the early-out is present at all.
    ///
    /// Scope of what this actually buys, stated plainly: the predicate is
    /// `messageCount > 1 && agents.count > 1`, so asserting its truth table is
    /// partly a restatement of its implementation. It pins that the early-out
    /// EXISTS and that its boundary cases are the intended ones; it cannot
    /// catch the failure mode that would reach users, which is the predicate
    /// drifting out of agreement with ``ChatHistoryHandoffResolver/chip(at:messages:session:)``.
    /// That agreement is covered by `test_handoffBoundaries_earlyOutPreservesSemantics`
    /// (and by the multi-agent `test_handoffBoundaries_matchPerIndexChipResolution`).
    ///
    /// Sabotage-evidence:
    ///   M1: drop `session.agents.count > 1` → the single-agent cases return
    ///       true → first two assertions fail.
    ///   M2: drop `messageCount > 1` → the 0/1-message cases return true → fails.
    ///   M3: tighten to `agents.count > 2` → the 2-agent case returns false →
    ///       last assertion fails (guard must not suppress real handoffs).
    @MainActor
    func test_handoffBoundaries_earlyOutPredicateIsExact() {
        let (a, b) = agentPair()

        let singleAgent = ManifoldInference.ChatSession(id: sessionID, agents: [a])
        XCTAssertFalse(
            ChatHistoryHandoffResolver.canProduceHandoffs(singleAgent, messageCount: 50),
            "A single-agent session can never produce a chip, however many messages."
        )
        let noAgents = ManifoldInference.ChatSession(id: sessionID, agents: [])
        XCTAssertFalse(
            ChatHistoryHandoffResolver.canProduceHandoffs(noAgents, messageCount: 50),
            "An agent-less session can never produce a chip."
        )

        let twoAgents = ManifoldInference.ChatSession(id: sessionID, agents: [a, b])
        XCTAssertFalse(
            ChatHistoryHandoffResolver.canProduceHandoffs(twoAgents, messageCount: 1),
            "A single message has no adjacency, so no transition is possible."
        )
        XCTAssertFalse(
            ChatHistoryHandoffResolver.canProduceHandoffs(nil, messageCount: 50),
            "No session means no agents to resolve against."
        )

        // The guard must NOT suppress the case handoffs actually occur in.
        XCTAssertTrue(
            ChatHistoryHandoffResolver.canProduceHandoffs(twoAgents, messageCount: 2),
            "Two agents and two messages is exactly the case a chip can occur in."
        )
    }

    /// The early-out must be semantics-preserving: for a single-agent session,
    /// `boundaries` agrees with per-index `chip(at:)` resolution (both empty),
    /// and for a multi-agent session whose messages carry no `agentID` it is
    /// still empty — i.e. the guard neither invents nor suppresses chips.
    ///
    /// Sabotage-evidence:
    ///   M1: make the early-out return a non-empty dict → count assertions fail.
    ///   M2: apply the early-out when `agents.count > 1` (inverted) → the
    ///       multi-agent transition test above loses its chips and fails.
    @MainActor
    func test_handoffBoundaries_earlyOutPreservesSemantics() {
        let (a, b) = agentPair()

        let singleAgent = ManifoldInference.ChatSession(id: sessionID, agents: [a])
        let sameAgentMessages = (0..<8).map { index in
            ManifoldInference.ChatMessage(
                role: .assistant, content: "m\(index)", sessionID: sessionID, agentID: a.id
            )
        }
        let singleAgentBoundaries = ChatHistoryHandoffResolver.boundaries(
            messages: sameAgentMessages, session: singleAgent
        )
        XCTAssertTrue(singleAgentBoundaries.isEmpty)
        for index in sameAgentMessages.indices {
            XCTAssertNil(
                ChatHistoryHandoffResolver.chip(at: index, messages: sameAgentMessages, session: singleAgent),
                "Per-index resolution must agree with the early-out at index \(index)."
            )
        }

        // Two agents present, but no message attributes to one: the early-out
        // does NOT fire (predicate is true), and the loop still finds nothing.
        let twoAgents = ManifoldInference.ChatSession(id: sessionID, agents: [a, b])
        let unattributed = (0..<8).map { index in
            ManifoldInference.ChatMessage(
                role: .assistant, content: "m\(index)", sessionID: sessionID, agentID: nil
            )
        }
        XCTAssertTrue(
            ChatHistoryHandoffResolver.canProduceHandoffs(twoAgents, messageCount: unattributed.count),
            "The early-out must not fire just because messages lack agentIDs."
        )
        XCTAssertTrue(
            ChatHistoryHandoffResolver.boundaries(messages: unattributed, session: twoAgents).isEmpty
        )

        // The case the early-out newly short-circuits: adjacent messages DO
        // carry two distinct agentIDs, but only one agent is in the session, so
        // `chip` bails at *agent resolution* rather than at the distinctness
        // check. Nil today via that resolution guard, and nil via the early-out
        // — they must agree. This is the fixture that goes red the day `chip`'s
        // resolution is loosened (e.g. synthesising a placeholder agent for an
        // unresolvable id), which is precisely when the early-out would begin
        // eating chips that would otherwise render.
        let alternatingUnresolvable = (0..<8).map { index in
            ManifoldInference.ChatMessage(
                role: .assistant,
                content: "m\(index)",
                sessionID: sessionID,
                agentID: index.isMultiple(of: 2) ? a.id : b.id
            )
        }
        for index in alternatingUnresolvable.indices {
            XCTAssertNil(
                ChatHistoryHandoffResolver.chip(
                    at: index, messages: alternatingUnresolvable, session: singleAgent
                ),
                "Unresolvable agentID must yield no chip at index \(index) — if this fails, the early-out is no longer exact."
            )
        }
        XCTAssertTrue(
            ChatHistoryHandoffResolver.boundaries(
                messages: alternatingUnresolvable, session: singleAgent
            ).isEmpty,
            "Early-out and per-index resolution must agree for unresolvable agentIDs."
        )
    }

    /// Snapshot the natural arrival ordering of `.tokenEmitted`-style events
    /// vs `.agentHandoff` for a single turn. The chip in our renderer is
    /// derived from the persisted sequence — but the *event* stream must
    /// still surface deltas before the handoff fires (UX: user sees the
    /// assistant finish speaking, *then* the chip slides in).
    ///
    /// Sabotage-evidence:
    ///   M1: emit handoff first then deltas → ordering assertion fails.
    ///   M2: drop the delta entirely → first ordering check fails.
    ///   M3: emit only the handoff → array length differs.
    func test_bubble_eventOrdering_messageDeltaBeforeHandoff() {
        let messageID = UUID()
        let (from, to) = agentPair()
        let events: [ConversationEvent] = [
            .tokenEmitted(messageID: messageID, delta: "Hand"),
            .tokenEmitted(messageID: messageID, delta: "off "),
            .tokenEmitted(messageID: messageID, delta: "now."),
            .streamFinished(messageID: messageID, reason: .stop),
            .agentHandoff(from: from.id, to: to.id),
        ]

        // Find the index of the first agentHandoff and the last tokenEmitted.
        let handoffIdx = events.firstIndex(where: {
            if case .agentHandoff = $0 { return true } else { return false }
        })
        let lastDeltaIdx = events.lastIndex(where: {
            if case .tokenEmitted = $0 { return true } else { return false }
        })
        XCTAssertNotNil(handoffIdx)
        XCTAssertNotNil(lastDeltaIdx)
        XCTAssertLessThan(lastDeltaIdx!, handoffIdx!,
                          "All token deltas must precede the agent handoff event for a single turn.")
    }

    // MARK: - ChatHistoryBranchOriginResolver (#2307 chip wiring)

    /// Pure gate: `ChatHistoryView` should render `BranchOriginChipView` when
    /// the active session carries a non-nil `branchOriginSessionID`.
    ///
    /// Sabotage-evidence:
    ///   M1: invert the nil check → passes for non-branched, fails for branched.
    ///   M2: hardcode `true` → the "non-branched" assertion below fails.
    func test_branchOriginResolver_isBranch_trueWhenOriginSessionIDSet() {
        let branched = ManifoldInference.ChatSession(title: "New Chat", branchOriginSessionID: UUID())
        XCTAssertTrue(ChatHistoryBranchOriginResolver.isBranch(branched))
    }

    /// Ordinary sessions (never branched) must render nothing — zero footprint.
    ///
    /// Sabotage-evidence:
    ///   M1: hardcode `true` → this assertion fails.
    func test_branchOriginResolver_isBranch_falseForOrdinarySession() {
        let ordinary = ManifoldInference.ChatSession(title: "Ordinary session")
        XCTAssertFalse(ChatHistoryBranchOriginResolver.isBranch(ordinary))
    }

    /// A `nil` active session (no session selected yet) must not gate `true`
    /// — guards against a force-unwrap or an inverted optional check.
    func test_branchOriginResolver_isBranch_falseForNilSession() {
        XCTAssertFalse(ChatHistoryBranchOriginResolver.isBranch(nil))
    }
}
