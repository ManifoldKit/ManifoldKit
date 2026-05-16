import XCTest
import ManifoldInference
import ManifoldRuntime
@testable import ManifoldUI

/// Unit tests for ``ChatSessionManager`` — verifies that the teardown
/// choreography delegates to each injected closure and that selection
/// resolution follows the persisted model/endpoint priority rules.
///
/// Tests drive `ChatSessionManager` in isolation without constructing a
/// full `ChatViewModel`, confirming the extraction keeps the type
/// decoupled from its collaborators.
@MainActor
final class ChatSessionManagerTests: XCTestCase {

    // MARK: - Helpers

    private func makeEndpoint(name: String = "Test") -> APIEndpointRecord {
        APIEndpointRecord(name: name, provider: .openAI)
    }

    private func makeModel(name: String = "Local") -> ModelInfo {
        ModelInfo(
            name: name,
            fileName: "\(name).bin",
            url: URL(fileURLWithPath: "/\(name).bin"),
            fileSize: 0,
            modelType: .gguf
        )
    }

    private func silentMgr() -> ChatSessionManager {
        let mgr = ChatSessionManager()
        mgr.discardRequests = { _ in }
        mgr.resetConversation = {}
        mgr.secureWipe = {}
        mgr.applyPromptTemplate = { _ in }
        mgr.cancelActiveStreamHandle = {}
        mgr.resetToolApprovals = {}
        mgr.cancelBackgroundTask = {}
        mgr.refreshAvailableEndpoints = {}
        mgr.resolveModel = { _ in nil }
        mgr.resolveEndpoint = { _ in nil }
        return mgr
    }

    // MARK: - isRestoringSession

    func test_isRestoringSession_defaultsFalse() {
        let mgr = ChatSessionManager()
        XCTAssertFalse(mgr.isRestoringSession)
    }

    func test_isRestoringSession_canBeToggled() {
        let mgr = ChatSessionManager()
        mgr.isRestoringSession = true
        XCTAssertTrue(mgr.isRestoringSession)
        mgr.isRestoringSession = false
        XCTAssertFalse(mgr.isRestoringSession)
    }

    // MARK: - teardown closure ordering

    func test_teardown_invokesAllClosures() async {
        let mgr = ChatSessionManager()
        var log: [String] = []

        mgr.discardRequests = { _ in log.append("discard") }
        mgr.resetConversation = { log.append("reset") }
        mgr.secureWipe = { log.append("wipe") }
        mgr.applyPromptTemplate = { _ in log.append("template") }
        mgr.cancelActiveStreamHandle = { log.append("handle") }
        mgr.resetToolApprovals = { log.append("approvals") }
        mgr.cancelBackgroundTask = { log.append("bg") }
        mgr.refreshAvailableEndpoints = { log.append("endpoints") }
        mgr.resolveModel = { _ in nil }
        mgr.resolveEndpoint = { _ in nil }

        _ = await mgr.teardown(
            sessionID: UUID(),
            promptTemplate: .chatML,
            selectionState: SessionController.SessionSelectionState(
                selectedModelID: nil, selectedEndpointID: nil
            )
        )

        // discardRequests must run before resetConversation/secureWipe (issue #965).
        XCTAssertEqual(log.first, "discard",
            "discardRequests must run first to avoid KV-cache mutation races")
        XCTAssertTrue(log.contains("reset"))
        XCTAssertTrue(log.contains("wipe"))
        XCTAssertTrue(log.contains("template"))
        XCTAssertTrue(log.contains("handle"))
        XCTAssertTrue(log.contains("approvals"))
        XCTAssertTrue(log.contains("bg"))
        XCTAssertTrue(log.contains("endpoints"))
        XCTAssertEqual(log.count, 8)
    }

    // Sabotage: wiring closures in a different order must not change execution order.
    func test_teardown_discardFirstRegardlessOfClosureAssignmentOrder() async {
        let mgr = ChatSessionManager()
        var log: [String] = []

        // Intentionally assign resetConversation before discardRequests.
        mgr.resetConversation = { log.append("reset") }
        mgr.discardRequests = { _ in log.append("discard") }
        mgr.secureWipe = {}
        mgr.applyPromptTemplate = { _ in }
        mgr.cancelActiveStreamHandle = {}
        mgr.resetToolApprovals = {}
        mgr.cancelBackgroundTask = {}
        mgr.refreshAvailableEndpoints = {}
        mgr.resolveModel = { _ in nil }
        mgr.resolveEndpoint = { _ in nil }

        _ = await mgr.teardown(
            sessionID: UUID(),
            promptTemplate: .chatML,
            selectionState: SessionController.SessionSelectionState(
                selectedModelID: nil, selectedEndpointID: nil
            )
        )

        XCTAssertEqual(log.first, "discard",
            "discardRequests must always execute before resetConversation")
    }

    // MARK: - selection resolution

    func test_teardown_returnsNilsWhenNothingPersisted() async {
        let mgr = silentMgr()

        let result = await mgr.teardown(
            sessionID: UUID(),
            promptTemplate: .chatML,
            selectionState: SessionController.SessionSelectionState(
                selectedModelID: nil, selectedEndpointID: nil
            )
        )

        XCTAssertNil(result.resolvedModel)
        XCTAssertNil(result.resolvedEndpoint)
    }

    func test_teardown_resolvesEndpointWhenIDPresent() async {
        let mgr = silentMgr()
        let endpoint = makeEndpoint()
        mgr.resolveEndpoint = { id in id == endpoint.id ? endpoint : nil }

        let result = await mgr.teardown(
            sessionID: UUID(),
            promptTemplate: .chatML,
            selectionState: SessionController.SessionSelectionState(
                selectedModelID: nil, selectedEndpointID: endpoint.id
            )
        )

        XCTAssertEqual(result.resolvedEndpoint?.id, endpoint.id)
        XCTAssertNil(result.resolvedModel)
    }

    func test_teardown_resolvesModelWhenIDPresent() async {
        let mgr = silentMgr()
        let model = makeModel()
        mgr.resolveModel = { id in id == model.id ? model : nil }

        let result = await mgr.teardown(
            sessionID: UUID(),
            promptTemplate: .chatML,
            selectionState: SessionController.SessionSelectionState(
                selectedModelID: model.id, selectedEndpointID: nil
            )
        )

        XCTAssertEqual(result.resolvedModel?.id, model.id)
        XCTAssertNil(result.resolvedEndpoint)
    }

    // MARK: - applySelection

    func test_applySelection_prefersEndpointOverModel() {
        let mgr = ChatSessionManager()

        var modelCallCount = 0
        var appliedEndpoint: APIEndpointRecord?

        mgr.applyModelSelection = { _ in modelCallCount += 1 }
        mgr.applyEndpointSelection = { appliedEndpoint = $0 }

        let endpoint = makeEndpoint(name: "E")
        let model = makeModel(name: "M")
        mgr.applySelection(ChatSessionManager.TeardownResult(
            resolvedModel: model,
            resolvedEndpoint: endpoint
        ))

        // When an endpoint is resolved it wins; applyModelSelection must not be called.
        XCTAssertEqual(appliedEndpoint?.id, endpoint.id)
        XCTAssertEqual(modelCallCount, 0,
            "applyModelSelection must not be called when endpoint is resolved")
    }

    func test_applySelection_usesModelWhenNoEndpoint() {
        let mgr = ChatSessionManager()

        var appliedModel: ModelInfo?
        var endpointCallCount = 0

        mgr.applyModelSelection = { appliedModel = $0 }
        mgr.applyEndpointSelection = { _ in endpointCallCount += 1 }

        let model = makeModel()
        mgr.applySelection(ChatSessionManager.TeardownResult(
            resolvedModel: model,
            resolvedEndpoint: nil
        ))

        XCTAssertEqual(appliedModel?.id, model.id)
        XCTAssertEqual(endpointCallCount, 0,
            "applyEndpointSelection must not be called when only model is resolved")
    }

    func test_applySelection_clearsWhenBothNil() {
        let mgr = ChatSessionManager()

        var appliedModelArg: ModelInfo?? = .none    // .none = closure not called
        var appliedEndpointArg: APIEndpointRecord?? = .none

        // Wrap optionals in another optional to distinguish "not called" from "called with nil".
        mgr.applyModelSelection = { appliedModelArg = .some($0) }
        mgr.applyEndpointSelection = { appliedEndpointArg = .some($0) }

        mgr.applySelection(ChatSessionManager.TeardownResult(resolvedModel: nil, resolvedEndpoint: nil))

        // Both closures must be called with nil to clear any prior selection.
        guard case .some(let m) = appliedModelArg else {
            XCTFail("applyModelSelection was not called"); return
        }
        guard case .some(let e) = appliedEndpointArg else {
            XCTFail("applyEndpointSelection was not called"); return
        }
        XCTAssertNil(m)
        XCTAssertNil(e)
    }

    // MARK: - nil-closure safety

    func test_teardown_nilClosures_doesNotCrash() async {
        // A manager with no closures wired must not crash during teardown —
        // optional chaining on each closure is the contract.
        let mgr = ChatSessionManager()
        _ = await mgr.teardown(
            sessionID: UUID(),
            promptTemplate: .chatML,
            selectionState: SessionController.SessionSelectionState(
                selectedModelID: nil, selectedEndpointID: nil
            )
        )
        // Reaching this line is the assertion — no crash occurred.
        XCTAssertTrue(true, "teardown completed without crashing")
    }

    func test_applySelection_whenBothClosuresNil_doesNotCrash() {
        // applySelection must not crash when neither applyModelSelection nor
        // applyEndpointSelection has been wired — closures are optional.
        let mgr = ChatSessionManager()
        mgr.applySelection(ChatSessionManager.TeardownResult(
            resolvedModel: nil, resolvedEndpoint: nil
        ))
        // Reaching this line is the assertion — no crash occurred.
        XCTAssertTrue(true, "applySelection completed without crashing")
    }

    // MARK: - closure forwarding

    func test_teardown_promptTemplateForwardedToApplyPromptTemplateClosure() async {
        let mgr = silentMgr()
        var receivedTemplate: PromptTemplate?
        mgr.applyPromptTemplate = { receivedTemplate = $0 }

        _ = await mgr.teardown(
            sessionID: UUID(),
            promptTemplate: .chatML,
            selectionState: SessionController.SessionSelectionState(
                selectedModelID: nil, selectedEndpointID: nil
            )
        )

        XCTAssertEqual(receivedTemplate, .chatML,
            "teardown must forward the supplied promptTemplate to applyPromptTemplate")
    }

    func test_teardown_sessionIDForwardedToDiscardRequestsClosure() async {
        let mgr = silentMgr()
        let expectedID = UUID()
        var receivedID: UUID?
        mgr.discardRequests = { receivedID = $0 }

        _ = await mgr.teardown(
            sessionID: expectedID,
            promptTemplate: .chatML,
            selectionState: SessionController.SessionSelectionState(
                selectedModelID: nil, selectedEndpointID: nil
            )
        )

        XCTAssertEqual(receivedID, expectedID,
            "teardown must forward the supplied sessionID to discardRequests")
    }
}
