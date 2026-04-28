import Testing
import Foundation
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
import BaseChatInference
import BaseChatTestSupport

/// Day-one user journey E2E — exercises a full first-session experience end to
/// end in one test so that regressions in the HAND-OFFS between discovery,
/// loading, sending, cancellation, regeneration, model switching, and session
/// persistence are caught. The one-feature-per-test coverage already in
/// `BaseChatE2ETests` validates each step in isolation; this test exists
/// specifically to catch bugs that only surface when these features run
/// back-to-back against the same ChatViewModel instance.
///
/// Uses `SlowMockBackend` and in-memory SwiftData so that step 5 can actually
/// observe mid-stream cancellation (SlowMockBackend yields with a per-token
/// delay, so `stopGeneration()` has real work to cancel). No hardware or real
/// model files are required.
@Suite("User Journey E2E")
@MainActor
final class UserJourneyE2ETests {

    private let container: ModelContainer
    private let context: ModelContext
    private let backend: SlowMockBackend
    private let vm: ChatViewModel
    private let sessionManager: SessionManagerViewModel
    private let modelsDir: URL
    private let persistence: SwiftDataPersistenceProvider

    init() throws {
        modelsDir = try makeE2ETempDir()

        container = try ModelContainerFactory.makeInMemoryContainer()
        context = container.mainContext

        backend = SlowMockBackend()
        backend.isModelLoaded = false
        // 50ms matches the convention in CancellationTests — tight enough to
        // keep the test fast, loose enough to stay stable on loaded CI runners.
        backend.delayPerToken = .milliseconds(50)

        // Register a factory that always returns the same backend so the
        // model switch in step 7 routes through the same instance — just
        // re-loads it under a different model descriptor.
        let backendRef = backend
        let service = InferenceService()
        service.registerBackendFactory { _ in backendRef }

        persistence = SwiftDataPersistenceProvider(modelContext: context)
        let storage = ModelStorageService(baseDirectory: modelsDir)
        vm = ChatViewModel(inferenceService: service, modelStorage: storage)
        vm.configure(persistence: persistence)

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence)
    }

    deinit {
        cleanupE2ETempDir(modelsDir)
    }

    // MARK: - Helpers

    @discardableResult
    private func writeGGUF(named name: String) throws -> URL {
        let url = modelsDir.appendingPathComponent(name)
        var data = Data(ggufMagic)
        data.append(Data(repeating: 0xFF, count: 1_100_000))
        try data.write(to: url)
        return url
    }

    /// Waits until the message at `atIndex` exists and has non-empty content,
    /// or fails after `timeout`. Used to synchronise with streaming tokens
    /// when calling `stopGeneration()` mid-stream.
    private func awaitFirstToken(atIndex index: Int, timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if vm.messages.count > index, !vm.messages[index].content.isEmpty {
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for first token at index \(index)")
    }

    // MARK: - Day-one journey

    @Test("Day-one journey: empty state -> discover -> load -> send -> cancel -> regenerate -> switch model -> persist")
    func test_dayOneUserJourney_firstChatThroughModelSwitch() async throws {
        // 1. Empty state — freshly constructed VM has no models and nothing selected.
        #expect(vm.availableModels.isEmpty)
        #expect(vm.selectedModel == nil)
        #expect(!vm.isModelLoaded)

        // 2. Discovery — write a GGUF to the models directory and refresh.
        try writeGGUF(named: "journey-model-a.gguf")
        vm.refreshModels()
        #expect(vm.availableModels.count == 1)
        let modelA = try #require(vm.availableModels.first)
        #expect(modelA.modelType == .gguf)

        // 3. Select + load — pick modelA and load the (mock) backend.
        vm.selectedModel = modelA
        await vm.loadSelectedModel()
        #expect(vm.isModelLoaded)
        #expect(vm.errorMessage == nil)

        // 4. First session + first message — create a session, activate it,
        //    and send a message. User + assistant messages must persist.
        let session = try await sessionManager.createSession(title: "Day One")
        sessionManager.activeSession = session
        await vm.switchToSession(session)

        // switchToSession resets selectedModel to match the session's
        // selectedModelID, which is still nil for a brand-new session.
        // Re-apply modelA and persist so the session records it.
        vm.selectedModel = modelA
        try await vm.saveSettingsToSession()

        backend.tokensToYield = ["Hi", " there"]
        vm.inputText = "Hello"
        await vm.sendMessage()

        #expect(vm.messages.count == 2)
        #expect(vm.messages[0].role == .user)
        #expect(vm.messages[0].content == "Hello")
        #expect(vm.messages[1].role == .assistant)
        #expect(vm.messages[1].content == "Hi there")

        // Cross-check: the messages must also exist in SwiftData, not just in
        // the in-memory array. If persistence silently broke, this fetch would
        // return zero rows even though vm.messages still holds them.
        let sessionID = session.id
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        var dbMessages = try context.fetch(descriptor)
        #expect(dbMessages.count == 2)
        #expect(dbMessages[0].content == "Hello")
        #expect(dbMessages[1].content == "Hi there")

        // 5. Mid-stream cancel — configure a long, slow token stream, start
        //    the send in a background Task, wait for the first token to land,
        //    then call stopGeneration(). With SlowMockBackend's per-token
        //    delay we can reliably cancel mid-stream. Tokens are unique so
        //    the repetition detector never fires and truncates content on
        //    our behalf.
        let longStream = (0..<40).map { "tok\($0) " }
        backend.tokensToYield = longStream
        vm.inputText = "Tell me a long story"
        let sendTask = Task { await vm.sendMessage() }
        // Wait until the new assistant message (index 3) has received at
        // least one token, then cancel mid-stream.
        await awaitFirstToken(atIndex: 3)
        vm.stopGeneration()
        await sendTask.value

        #expect(!vm.isGenerating)
        #expect(vm.messages.count == 4, "Second user + assistant pair must exist")
        #expect(vm.messages[2].role == .user)
        #expect(vm.messages[2].content == "Tell me a long story")
        #expect(vm.messages[3].role == .assistant)
        let cancelledAssistant = vm.messages[3]
        // Partial-or-complete invariant: content must be non-empty (the first
        // token landed before stop), and must not be the full 40-token output.
        #expect(!cancelledAssistant.content.isEmpty, "Partial content must be preserved")
        #expect(cancelledAssistant.content != longStream.joined(), "Generation must have been cancelled before completion")

        // Persistence contract check: stopGeneration() promises to save the
        // partial content under the cancelled assistant's ID. Fetch by ID and
        // verify that exactly one row exists whose content matches the in-memory
        // partial.
        let cancelID = cancelledAssistant.id
        let expectedPartial = cancelledAssistant.content
        let cancelDescriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.id == cancelID }
        )
        let cancelRows = try context.fetch(cancelDescriptor)
        #expect(cancelRows.count == 1, "stopGeneration should leave exactly one persisted row")
        #expect(
            cancelRows.contains { $0.content == expectedPartial },
            "Persisted partial content must match the in-memory partial"
        )

        // 6. Regenerate — replace the last assistant message with a fresh one.
        backend.tokensToYield = ["Regenerated", " reply"]
        await vm.regenerateLastResponse()

        #expect(vm.messages.count == 4, "Regenerate replaces rather than appends")
        #expect(vm.messages[3].role == .assistant)
        #expect(vm.messages[3].content == "Regenerated reply")
        #expect(vm.messages[3].id != cancelledAssistant.id, "A new assistant record must replace the cancelled one")

        // 7. Switch model — discover a second GGUF, select it, load it.
        //    Existing messages must remain in the UI.
        try writeGGUF(named: "journey-model-b.gguf")
        vm.refreshModels()
        #expect(vm.availableModels.count == 2)
        let modelB = try #require(vm.availableModels.first { $0.fileName == "journey-model-b.gguf" })
        #expect(modelB.id != modelA.id)

        vm.selectedModel = modelB
        try await vm.saveSettingsToSession()
        await vm.loadSelectedModel()
        #expect(vm.isModelLoaded)
        #expect(vm.messages.count == 4, "Switching models must not drop conversation history")

        // 8. Send against new model — third turn lands in the same session.
        backend.tokensToYield = ["Model", " B", " reply"]
        vm.inputText = "Follow-up on model B"
        await vm.sendMessage()

        #expect(vm.messages.count == 6)
        #expect(vm.messages[4].role == .user)
        #expect(vm.messages[4].content == "Follow-up on model B")
        #expect(vm.messages[5].role == .assistant)
        #expect(vm.messages[5].content == "Model B reply")

        // In-memory ordering and content assertions — these verify the real
        // "full HISTORY is intact after model switch" contract. The VM tracks
        // the authoritative sequence the user actually sees.
        #expect(
            vm.messages.map(\.role) == [.user, .assistant, .user, .assistant, .user, .assistant],
            "VM message roles must alternate user/assistant in send order"
        )
        #expect(vm.messages[0].content == "Hello", "First user turn must survive")
        #expect(
            vm.messages[3].content == "Regenerated reply",
            "Regenerated assistant reply must survive the model switch"
        )
        #expect(vm.messages[5].content == "Model B reply", "Last turn must land under modelB")

        // DB-side history check: after cancel + regenerate, persistence should
        // contain exactly the six visible turns with no orphaned assistant row.
        descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        dbMessages = try context.fetch(descriptor)
        #expect(dbMessages.count == 6, "Full conversation history must be persisted")
        // Content anchors that must exist somewhere in the persisted set —
        // these prove the real turns landed on disk.
        #expect(
            dbMessages.contains { $0.content == "Hello" && $0.role == .user },
            "First user turn must be persisted"
        )
        #expect(
            dbMessages.contains { $0.content == "Regenerated reply" && $0.role == .assistant },
            "Regenerated assistant reply must survive the model switch on disk"
        )
        #expect(
            dbMessages.contains { $0.content == "Follow-up on model B" && $0.role == .user },
            "Follow-up user turn must be persisted"
        )
        #expect(
            dbMessages.contains { $0.content == "Model B reply" && $0.role == .assistant },
            "Last assistant turn must land under modelB on disk"
        )

        // 9. Session persistence — reload sessions, grab the fresh record,
        //    and verify selectedModelID restored correctly to modelB.
        await sessionManager.loadSessions()
        let freshSession = try #require(sessionManager.sessions.first { $0.title == "Day One" })
        #expect(freshSession.selectedModelID == modelB.id)

        // Switching back through the fresh session record must re-resolve
        // modelB from availableModels (it's still on disk) and reload messages.
        await vm.switchToSession(freshSession)
        #expect(vm.selectedModel?.id == modelB.id)
        // All expected content anchors must round-trip through the reload.
        #expect(
            vm.messages.contains { $0.content == "Hello" && $0.role == .user },
            "Reloaded session must restore the first user turn"
        )
        #expect(
            vm.messages.contains { $0.content == "Regenerated reply" && $0.role == .assistant },
            "Reloaded session must restore the regenerated reply"
        )
        #expect(
            vm.messages.contains { $0.content == "Model B reply" && $0.role == .assistant },
            "Reloaded session must restore the model-B reply"
        )
        #expect(vm.messages.count == 6, "Reloaded session must restore exactly all turns")

        // Independent verification: bypass sessionManager entirely and read
        // the session record straight from SwiftData. This proves that
        // saveSettingsToSession actually reached the store in step 7 — not
        // just the in-memory sessions array that loadSessions() repopulates.
        //
        // Sabotage verified: removing the `try await vm.saveSettingsToSession()` call
        // in step 7 causes the assertion below to fail with
        // `storedSessions.first?.selectedModelID == modelA.id` (or nil) instead
        // of modelB.id, confirming this assertion catches the real persistence
        // contract and is not accidentally vacuous.
        let storedSessionID = session.id
        let sessionDescriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.id == storedSessionID }
        )
        let storedSessions = try context.fetch(sessionDescriptor)
        #expect(storedSessions.count == 1)
        #expect(
            storedSessions.first?.selectedModelID == modelB.id,
            "saveSettingsToSession must persist selectedModelID to the SwiftData store"
        )
    }
}
