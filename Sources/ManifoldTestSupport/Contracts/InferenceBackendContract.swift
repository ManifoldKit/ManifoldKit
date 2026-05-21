#if canImport(XCTest)
import XCTest
import ManifoldInference

// MARK: - InferenceBackendContract

/// Opt-in XCTestCase mixin that exercises the ``InferenceBackend`` protocol
/// contract against any conforming implementation.
///
/// Adopt this protocol in a concrete `XCTestCase` subclass to verify that your
/// backend satisfies the documented ``InferenceBackend`` invariants:
///
/// ```swift
/// final class MockInferenceBackendContractTests: XCTestCase, InferenceBackendContract {
///     var subject: any InferenceBackend { MockInferenceBackend() }
/// }
/// ```
///
/// Contract methods are named `assertInferenceBackend_*` rather than `test_*`
/// because XCTest does not discover protocol-extension test methods on its own.
/// The concrete subclass must call each assertion helper from a `test_`-prefixed
/// method to make it discoverable.
@MainActor
public protocol InferenceBackendContract: AnyObject {
    /// Returns a fresh, unloaded backend under test for each assertion call.
    /// The default implementation of ``makeTestURL()`` returns a synthetic URL;
    /// override it if your backend validates the path before loading.
    func makeInferenceBackend() -> any InferenceBackend

    /// Returns the URL passed to ``InferenceBackend/loadModel(from:plan:)``
    /// during contract assertions. The default returns a synthetic placeholder
    /// that the ``MockInferenceBackend`` ignores; backends that validate the URL
    /// must override this to return a URL that satisfies their preconditions.
    func makeTestModelURL() -> URL
}

extension InferenceBackendContract {
    public func makeTestModelURL() -> URL {
        URL(fileURLWithPath: "/tmp/ManifoldContractTests/contract-test.gguf")
    }
}

extension InferenceBackendContract where Self: XCTestCase {

    // MARK: - Load / State Lifecycle

    /// Asserts that a freshly-created backend reports ``isModelLoaded == false``
    /// before ``loadModel(from:plan:)`` has been called.
    public func assertInferenceBackend_freshBackendIsNotLoaded(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let backend = makeInferenceBackend()
        XCTAssertFalse(
            backend.isModelLoaded,
            "Fresh backend must report isModelLoaded == false before loadModel()",
            file: file, line: line
        )
    }

    /// Asserts that ``isGenerating`` is `false` before any generation call.
    public func assertInferenceBackend_freshBackendIsNotGenerating(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let backend = makeInferenceBackend()
        XCTAssertFalse(
            backend.isGenerating,
            "Fresh backend must report isGenerating == false before generate()",
            file: file, line: line
        )
    }

    /// Asserts that ``InferenceBackend/loadModel(from:plan:)`` transitions
    /// ``isModelLoaded`` to `true` and that
    /// ``InferenceBackend/unloadModel()`` transitions it back to `false`.
    public func assertInferenceBackend_loadUnloadCycleUpdatesIsModelLoaded(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let backend = makeInferenceBackend()
        let url = makeTestModelURL()
        try await backend.loadModel(from: url, plan: .testStub())
        XCTAssertTrue(
            backend.isModelLoaded,
            "isModelLoaded must be true after loadModel()",
            file: file, line: line
        )
        backend.unloadModel()
        XCTAssertFalse(
            backend.isModelLoaded,
            "isModelLoaded must be false after unloadModel()",
            file: file, line: line
        )
    }

    // MARK: - Capabilities

    /// Asserts that ``BackendCapabilities/maxContextTokens`` is positive.
    public func assertInferenceBackend_capabilitiesHavePositiveContextWindow(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let backend = makeInferenceBackend()
        XCTAssertGreaterThan(
            backend.capabilities.maxContextTokens,
            0,
            "BackendCapabilities.maxContextTokens must be > 0",
            file: file, line: line
        )
    }

    // MARK: - Generation

    /// Asserts that ``InferenceBackend/generate(prompt:systemPrompt:config:)``
    /// produces at least one event when a model is loaded.
    public func assertInferenceBackend_generateProducesEvents(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let backend = makeInferenceBackend()
        let url = makeTestModelURL()
        try await backend.loadModel(from: url, plan: .testStub())

        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        XCTAssertFalse(
            events.isEmpty,
            "generate() must produce at least one event",
            file: file, line: line
        )
    }

    // MARK: - Cancellation contract

    /// Asserts the core ``InferenceBackend/stopGeneration()`` contract:
    ///
    /// 1. Calling `stopGeneration()` when no generation is in progress is a no-op
    ///    (does not throw or crash).
    /// 2. After `stopGeneration()`, `isGenerating` is `false`.
    /// 3. After `stopGeneration()`, the backend accepts a new `generate()` call
    ///    without requiring `loadModel()` again ("ready for reuse" invariant).
    public func assertInferenceBackend_stopGenerationContract(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let backend = makeInferenceBackend()
        let url = makeTestModelURL()
        try await backend.loadModel(from: url, plan: .testStub())

        // (1) No-op when idle
        backend.stopGeneration()
        XCTAssertFalse(
            backend.isGenerating,
            "isGenerating must be false after no-op stopGeneration()",
            file: file, line: line
        )

        // (2) & (3) After a stop, backend is ready for a new generation
        let stream = try backend.generate(
            prompt: "Ping",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        backend.stopGeneration()
        XCTAssertFalse(
            backend.isGenerating,
            "isGenerating must be false after stopGeneration()",
            file: file, line: line
        )
        // Drain the cancelled stream — expect it to terminate (not hang)
        var drained = 0
        for try await _ in stream.events { drained += 1 }
        // (3) New generate() must succeed without reloading
        let stream2 = try backend.generate(
            prompt: "Pong",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        var events2: [GenerationEvent] = []
        for try await e in stream2.events { events2.append(e) }
        XCTAssertFalse(
            events2.isEmpty,
            "Backend must accept a new generate() after stopGeneration() (ready-for-reuse contract)",
            file: file, line: line
        )
    }

    // MARK: - resetConversation (default no-op is acceptable)

    /// Asserts that ``InferenceBackend/resetConversation()`` does not throw or
    /// crash, either before or after loading a model.
    public func assertInferenceBackend_resetConversationIsIdempotent(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let backend = makeInferenceBackend()
        // Safe before load
        backend.resetConversation()
        let url = makeTestModelURL()
        try await backend.loadModel(from: url, plan: .testStub())
        // Safe after load
        backend.resetConversation()
        XCTAssertTrue(
            backend.isModelLoaded,
            "resetConversation() must not unload the model",
            file: file, line: line
        )
    }
}
#endif
