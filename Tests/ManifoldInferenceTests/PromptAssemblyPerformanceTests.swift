import XCTest
@testable import ManifoldInference

final class PromptAssemblyPerformanceTests: XCTestCase {

    private static let sessionID = UUID()
    private static let messageContent = "This is a test message with realistic length to simulate a real conversation turn."
    private static let systemPrompt = "You are a helpful assistant."

    // MARK: - Helpers

    private func makeMessages(count: Int) -> [ChatMessageRecord] {
        (0..<count).map { i in
            let role: MessageRole = i % 2 == 0 ? .user : .assistant
            return ChatMessageRecord(role: role, content: Self.messageContent, sessionID: Self.sessionID)
        }
    }

    private func makeSlots(count: Int) -> [PromptSlot] {
        (0..<count).map { i in
            PromptSlot(
                id: "slot_\(i)",
                content: "This is extra slot content number \(i) that adds context to the conversation.",
                position: .atDepth(i),
                label: "Slot \(i)"
            )
        }
    }

    // MARK: - 200 messages, 0 extra slots

    func testPerf_assemble_200messages_noSlots() {
        let messages = makeMessages(count: 200)
        measure {
            _ = PromptAssembler.assemble(
                slots: [],
                messages: messages,
                systemPrompt: Self.systemPrompt,
                contextSize: 4096
            )
        }
    }

    // MARK: - 200 messages, 5 extra slots

    func testPerf_assemble_200messages_5slots() {
        let messages = makeMessages(count: 200)
        let slots = makeSlots(count: 5)
        measure {
            _ = PromptAssembler.assemble(
                slots: slots,
                messages: messages,
                systemPrompt: Self.systemPrompt,
                contextSize: 4096
            )
        }
    }
}
