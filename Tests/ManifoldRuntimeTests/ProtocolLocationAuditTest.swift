import XCTest
import Foundation
import ManifoldInference
import ManifoldRuntime

/// Tripwire that pins the persistence-port protocols and their port-only
/// types in ``ManifoldRuntime``.
///
/// Initiative I4 (May 2026) relocated ``MessageStore`` and ``SessionStore``
/// from ``ManifoldInference`` to ``ManifoldRuntime`` to align with the layering
/// rule documented in `CLAUDE.md`: ManifoldInference owns inference
/// orchestration (no persistence); ManifoldRuntime owns persistence-agnostic
/// ports plus the use cases that consume them. The records the ports traffic
/// in (``ChatMessage``, ``ChatSession``, ``MessagePart``,
/// ``MessageRole``) deliberately stayed in ManifoldInference because the
/// inference services (PromptAssembler, ContextWindowManager, TranscriptHealer)
/// also traffic in them — the dep DAG points ManifoldRuntime → ManifoldInference.
///
/// Future PRs that move these symbols back to ManifoldInference (or sideways
/// to a third module without updating this test) will fail here at runtime.
final class ProtocolLocationAuditTest: XCTestCase {

    func test_persistencePortProtocols_liveInManifoldRuntime() {
        XCTAssertTrue(
            String(reflecting: MessageStore.self).hasPrefix("ManifoldRuntime."),
            "MessageStore must live in ManifoldRuntime — got \(String(reflecting: MessageStore.self))"
        )
        XCTAssertTrue(
            String(reflecting: SessionStore.self).hasPrefix("ManifoldRuntime."),
            "SessionStore must live in ManifoldRuntime — got \(String(reflecting: SessionStore.self))"
        )
        XCTAssertTrue(
            String(reflecting: MessageStorePostWriteHook.self).hasPrefix("ManifoldRuntime."),
            "MessageStorePostWriteHook must live in ManifoldRuntime — got \(String(reflecting: MessageStorePostWriteHook.self))"
        )
        XCTAssertTrue(
            String(reflecting: SessionStorePostWriteHook.self).hasPrefix("ManifoldRuntime."),
            "SessionStorePostWriteHook must live in ManifoldRuntime — got \(String(reflecting: SessionStorePostWriteHook.self))"
        )
        XCTAssertTrue(
            String(reflecting: ChatPersistenceError.self).hasPrefix("ManifoldRuntime."),
            "ChatPersistenceError must live in ManifoldRuntime — got \(String(reflecting: ChatPersistenceError.self))"
        )
        XCTAssertTrue(
            String(reflecting: MessageSearchHit.self).hasPrefix("ManifoldRuntime."),
            "MessageSearchHit must live in ManifoldRuntime — got \(String(reflecting: MessageSearchHit.self))"
        )
    }

    /// The records remain in `ManifoldInference` because inference-layer
    /// services consume them and the dep DAG forbids `ManifoldInference →
    /// ManifoldRuntime`. Pinned here so a future move that breaks that
    /// invariant fails loudly rather than silently inverting the layering.
    func test_conversationRecords_liveInManifoldInference() {
        XCTAssertTrue(
            String(reflecting: ChatMessage.self).hasPrefix("ManifoldInference."),
            "ChatMessage must remain in ManifoldInference — got \(String(reflecting: ChatMessage.self))"
        )
        XCTAssertTrue(
            String(reflecting: ChatSession.self).hasPrefix("ManifoldInference."),
            "ChatSession must remain in ManifoldInference — got \(String(reflecting: ChatSession.self))"
        )
        XCTAssertTrue(
            String(reflecting: MessagePart.self).hasPrefix("ManifoldInference."),
            "MessagePart must remain in ManifoldInference — got \(String(reflecting: MessagePart.self))"
        )
        XCTAssertTrue(
            String(reflecting: MessageRole.self).hasPrefix("ManifoldInference."),
            "MessageRole must remain in ManifoldInference — got \(String(reflecting: MessageRole.self))"
        )
    }
}
