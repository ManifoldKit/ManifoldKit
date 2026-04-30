import XCTest
import BaseChatRuntime
import BaseChatPersistenceSwiftData
import BaseChatInference
@testable import BaseChatBackends

/// Shared contract assertions that every InferenceBackend implementation must satisfy.
/// Called from a single `test_contract_allInvariants()` method declared directly on
/// each adopting XCTestCase subclass — protocol extension methods are invisible to
/// XCTest's ObjC runtime and would never run.
enum BackendContractChecks {

    static func assertAllInvariants<B: InferenceBackend>(
        makingBackend makeBackend: () -> B,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // 1. Not loaded on init
        XCTAssertFalse(makeBackend().isModelLoaded,
            "Backend must report isModelLoaded == false before loadModel is called",
            file: file, line: line)

        // 2. Not generating on init
        XCTAssertFalse(makeBackend().isGenerating,
            "Backend must report isGenerating == false before any generation",
            file: file, line: line)

        // 3. generate() before load must throw
        XCTAssertThrowsError(
            try makeBackend().generate(prompt: "hello", systemPrompt: nil, config: GenerationConfig()),
            "generate() must throw when called before loadModel()",
            file: file, line: line
        )

        // 4. Capabilities must advertise at least one parameter
        XCTAssertFalse(makeBackend().capabilities.supportedParameters.isEmpty,
            "Backend must advertise at least one supported generation parameter",
            file: file, line: line)

        // 5. unloadModel() is idempotent
        let b1 = makeBackend()
        b1.unloadModel()
        b1.unloadModel()  // second call must not crash

        // 6. stopGeneration() before load must not crash
        makeBackend().stopGeneration()
    }
}
