import XCTest
@testable import ManifoldInference

final class ContextWindowPerformanceTests: XCTestCase {

    private static let sessionID = UUID()
    private static let messageContent = "This is a test message with realistic length to simulate a real conversation turn."
    private static let systemPrompt = "You are a helpful assistant."

    // MARK: - Helpers

    private func makeMessages(count: Int) -> [ChatMessage] {
        (0..<count).map { i in
            let role: MessageRole = i % 2 == 0 ? .user : .assistant
            return ChatMessage(role: role, content: Self.messageContent, sessionID: Self.sessionID)
        }
    }

    // MARK: - 100 messages

    func testPerf_trimMessages_100messages() {
        let messages = makeMessages(count: 100)
        PerfBudget.assert(.milliseconds(500)) {
            _ = ContextWindowManager.trimMessages(
                messages,
                systemPrompt: Self.systemPrompt,
                maxTokens: 4096,
                responseBuffer: 512
            )
        }
        measure {
            _ = ContextWindowManager.trimMessages(
                messages,
                systemPrompt: Self.systemPrompt,
                maxTokens: 4096,
                responseBuffer: 512
            )
        }
    }

    // MARK: - 500 messages

    func testPerf_trimMessages_500messages() {
        let messages = makeMessages(count: 500)
        PerfBudget.assert(.milliseconds(500)) {
            _ = ContextWindowManager.trimMessages(
                messages,
                systemPrompt: Self.systemPrompt,
                maxTokens: 4096,
                responseBuffer: 512
            )
        }
        measure {
            _ = ContextWindowManager.trimMessages(
                messages,
                systemPrompt: Self.systemPrompt,
                maxTokens: 4096,
                responseBuffer: 512
            )
        }
    }

    // MARK: - 1_000 messages

    func testPerf_trimMessages_1000messages() {
        let messages = makeMessages(count: 1_000)
        PerfBudget.assert(.milliseconds(500)) {
            _ = ContextWindowManager.trimMessages(
                messages,
                systemPrompt: Self.systemPrompt,
                maxTokens: 4096,
                responseBuffer: 512
            )
        }
        measure {
            _ = ContextWindowManager.trimMessages(
                messages,
                systemPrompt: Self.systemPrompt,
                maxTokens: 4096,
                responseBuffer: 512
            )
        }
    }
}
