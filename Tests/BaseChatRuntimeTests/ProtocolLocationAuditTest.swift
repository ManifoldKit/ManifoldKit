import XCTest
import Foundation
import BaseChatInference
import BaseChatRuntime

/// Tripwire that pins the persistence-port protocols and their port-only
/// types in ``BaseChatRuntime``.
///
/// Initiative I4 (May 2026) relocated ``MessageStore`` and ``SessionStore``
/// from ``BaseChatInference`` to ``BaseChatRuntime`` to align with the layering
/// rule documented in `CLAUDE.md`: BaseChatInference owns inference
/// orchestration (no persistence); BaseChatRuntime owns persistence-agnostic
/// ports plus the use cases that consume them. The records the ports traffic
/// in (``ChatMessageRecord``, ``ChatSessionRecord``, ``MessagePart``,
/// ``MessageRole``) deliberately stayed in BaseChatInference because the
/// inference services (PromptAssembler, ContextWindowManager, TranscriptHealer)
/// also traffic in them — the dep DAG points BaseChatRuntime → BaseChatInference.
///
/// Future PRs that move these symbols back to BaseChatInference (or sideways
/// to a third module without updating this test) will fail here at runtime.
final class ProtocolLocationAuditTest: XCTestCase {

    func test_persistencePortProtocols_liveInBaseChatRuntime() {
        XCTAssertTrue(
            String(reflecting: MessageStore.self).hasPrefix("BaseChatRuntime."),
            "MessageStore must live in BaseChatRuntime — got \(String(reflecting: MessageStore.self))"
        )
        XCTAssertTrue(
            String(reflecting: SessionStore.self).hasPrefix("BaseChatRuntime."),
            "SessionStore must live in BaseChatRuntime — got \(String(reflecting: SessionStore.self))"
        )
        XCTAssertTrue(
            String(reflecting: MessageStorePostWriteHook.self).hasPrefix("BaseChatRuntime."),
            "MessageStorePostWriteHook must live in BaseChatRuntime — got \(String(reflecting: MessageStorePostWriteHook.self))"
        )
        XCTAssertTrue(
            String(reflecting: SessionStorePostWriteHook.self).hasPrefix("BaseChatRuntime."),
            "SessionStorePostWriteHook must live in BaseChatRuntime — got \(String(reflecting: SessionStorePostWriteHook.self))"
        )
        XCTAssertTrue(
            String(reflecting: ChatPersistenceError.self).hasPrefix("BaseChatRuntime."),
            "ChatPersistenceError must live in BaseChatRuntime — got \(String(reflecting: ChatPersistenceError.self))"
        )
        XCTAssertTrue(
            String(reflecting: MessageSearchHit.self).hasPrefix("BaseChatRuntime."),
            "MessageSearchHit must live in BaseChatRuntime — got \(String(reflecting: MessageSearchHit.self))"
        )
    }

    /// The records remain in `BaseChatInference` because inference-layer
    /// services consume them and the dep DAG forbids `BaseChatInference →
    /// BaseChatRuntime`. Pinned here so a future move that breaks that
    /// invariant fails loudly rather than silently inverting the layering.
    func test_conversationRecords_liveInBaseChatInference() {
        XCTAssertTrue(
            String(reflecting: ChatMessageRecord.self).hasPrefix("BaseChatInference."),
            "ChatMessageRecord must remain in BaseChatInference — got \(String(reflecting: ChatMessageRecord.self))"
        )
        XCTAssertTrue(
            String(reflecting: ChatSessionRecord.self).hasPrefix("BaseChatInference."),
            "ChatSessionRecord must remain in BaseChatInference — got \(String(reflecting: ChatSessionRecord.self))"
        )
        XCTAssertTrue(
            String(reflecting: MessagePart.self).hasPrefix("BaseChatInference."),
            "MessagePart must remain in BaseChatInference — got \(String(reflecting: MessagePart.self))"
        )
        XCTAssertTrue(
            String(reflecting: MessageRole.self).hasPrefix("BaseChatInference."),
            "MessageRole must remain in BaseChatInference — got \(String(reflecting: MessageRole.self))"
        )
    }
}
