import XCTest
@testable import BaseChatBackends
import BaseChatRuntime
import BaseChatPersistenceSwiftData

final class MemoryStrategyBackendTests: XCTestCase {

    // MARK: - Cloud Backends (no hardware needed)

    #if CloudSaaS
    func test_openAIBackend_declaresExternalStrategy() {
        let backend = OpenAIBackend()
        XCTAssertEqual(backend.capabilities.memoryStrategy, .external)
    }

    func test_claudeBackend_declaresExternalStrategy() {
        let backend = ClaudeBackend()
        XCTAssertEqual(backend.capabilities.memoryStrategy, .external)
    }
    #endif

    // MARK: - Local Backends (hardware gated)

    #if MLX
    func test_mlxBackend_declaresResidentStrategy() {
        let backend = MLXBackend()
        XCTAssertEqual(backend.capabilities.memoryStrategy, .resident)
    }
    #endif

    #if Llama
    func test_llamaBackend_declaresMappableStrategy() throws {
        let shouldRun = ProcessInfo.processInfo.environment["RUN_LLAMA_TESTS"] == "1"
        try XCTSkipIf(!shouldRun, "Set RUN_LLAMA_TESTS=1 to run LlamaBackend tests in a supported environment")
        let backend = LlamaBackend()
        XCTAssertEqual(backend.capabilities.memoryStrategy, .mappable)
    }
    #endif
}
