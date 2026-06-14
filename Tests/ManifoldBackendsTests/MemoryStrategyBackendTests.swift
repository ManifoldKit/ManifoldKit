import XCTest
@testable import ManifoldFoundation
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
import ManifoldRuntime
import ManifoldPersistenceSwiftData

final class MemoryStrategyBackendTests: XCTestCase {

    // MARK: - Cloud Backends (no hardware needed)

    func test_openAIBackend_declaresExternalStrategy() {
        let backend = OpenAIBackend()
        XCTAssertEqual(backend.capabilities.memoryStrategy, .external)
    }

    func test_claudeBackend_declaresExternalStrategy() {
        let backend = ClaudeBackend()
        XCTAssertEqual(backend.capabilities.memoryStrategy, .external)
    }

    // MARK: - Local Backends (hardware gated)


}
