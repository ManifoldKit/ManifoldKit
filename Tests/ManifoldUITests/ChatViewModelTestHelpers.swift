@preconcurrency import XCTest
@testable import ManifoldUI

/// Event-driven helpers that replace Task.sleep polling in ChatViewModel tests.
extension ChatViewModel {

    /// Suspends until `isGenerating` becomes `expected`, or fails after `timeout`.
    @MainActor
    func awaitGenerating(
        _ expected: Bool,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        if isGenerating == expected { return }

        let expectation = XCTestExpectation(description: "isGenerating == \(expected)")
        let previous = onGeneratingChanged
        onGeneratingChanged = { value in
            previous?(value)
            if value == expected { expectation.fulfill() }
        }
        let result = await XCTWaiter().fulfillment(of: [expectation], timeout: timeout)
        onGeneratingChanged = previous
        if result != .completed {
            XCTFail("Timed out waiting for isGenerating == \(expected)", file: file, line: line)
        }
    }

    /// Suspends until at least one token has been written into the last assistant message.
    @MainActor
    func awaitFirstToken(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        if messages.count >= 2, !(messages.last?.content ?? "").isEmpty { return }

        // Poll with a very tight yield rather than a fixed sleep.
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if messages.count >= 2, !(messages.last?.content ?? "").isEmpty { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for first token", file: file, line: line)
    }
}
