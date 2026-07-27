import Foundation
import ManifoldInference
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldTestSupport

/// Compile-time consumer of every ManifoldKit public surface we want to lock.
///
/// **Compilation IS the assertion.** If any consumed type is removed, renamed,
/// or its signature drifts, this file fails to compile and CI fails. The
/// test method in `PublicSurfaceTests.swift` is a single `XCTAssertTrue(true)`
/// — there's nothing to assert at runtime.
///
/// ## What lives here
///
/// We intentionally do NOT aim for 100% public surface coverage. Instead, we
/// consume the **breakage-likely** surfaces:
///
/// 1. **Initializers and signatures** of types host apps construct directly
///    (records, configs, capabilities, runtime inputs).
/// 2. **Protocol witness shapes** that backends and adapters conform to —
///    a method-name change here would force every consumer to migrate.
/// 3. **Static and convenience APIs** that documentation and example code
///    references — silent removal of these is the most disruptive change a
///    library can make.
///
/// ## What's NOT here
///
/// - Internal types, package types, even when used in tests.
/// - SwiftUI views (their public surface is too volatile to freeze; `ManifoldUI`
///   tests cover the binding contract).
/// - Trait-gated types whose visibility depends on an opt-in trait —
///   `MCPClient`, `LlamaBackend`, etc. Add a per-trait `#if` consumer if a
///   PR breaks one of those.
///
/// ## Adding a new consumer
///
/// 1. If the type is in a module already imported here, add a one-line
///    construction or method invocation inside `consumeAllSurfaces()`.
/// 2. If the type lives in a new module, add the import at the top, the
///    module dependency in `Package.swift`'s `APIFreezeTests` target, then
///    the consumer line.
/// 3. Don't `@testable import` — the freeze is only meaningful for the
///    public surface.
@MainActor
enum PublicSurfaceConsumer {

    /// Statically referenced from `PublicSurfaceTests` so dead-code-elimination
    /// can't strip the consumer body. Returns `Void`; the body's purpose is
    /// purely to compile against the public surfaces named in it.
    static func consumeAllSurfaces() {
        consumeBackendCapabilities()
        consumeGenerationConfig()
        consumeMessageRole()
        consumeChatRecords()
        consumeMessagePart()
        consumeBackendOptInProtocols()
        consumeInferenceErrors()
        consumeRuntimeInputs()
        consumeMockBackend()
        consumeChaosBackend()
    }

    // MARK: - ManifoldInference

    private static func consumeBackendCapabilities() {
        // Default init.
        let _: BackendCapabilities = BackendCapabilities()

        // Init with every parameter — this is the public init signature
        // host apps and backends rely on.
        let caps = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty, .topK,
                                  .minP, .repetitionPenalty,
                                  .presencePenalty, .frequencyPenalty,
                                  .llamaDRY, .llamaXTC, .llamaMirostatV2],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            supportsNativeJSONMode: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .resident,
            maxOutputTokens: 4096,
            supportsStreaming: true,
            isRemote: false,
            supportsKVCachePersistence: false,
            supportsGrammarConstrainedSampling: false,
            supportsThinking: false,
            supportsVision: false,
            streamsToolCallArguments: false,
            supportsParallelToolCalls: false,
            supportsGuidedStructuredOutput: false,
            sharesMLXProcessResources: false,
            rendersFullPrompt: false
        )

        // Computed property accessors — host code reads these.
        _ = caps.contextWindowSize
        _ = caps.preferredStructuredOutputSupport
        _ = caps.visibleParameters
        // Codable round-trip — exposed publicly so callers can persist
        // capability snapshots.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        if let data = try? encoder.encode(caps) {
            _ = try? decoder.decode(BackendCapabilities.self, from: data)
        }

        // Enum cases publicly used in switch statements.
        let _: MemoryStrategy = .resident
        let _: MemoryStrategy = .mappable
        let _: MemoryStrategy = .external
        let _: CancellationStyle = .cooperative
        let _: CancellationStyle = .explicit
    }

    private static func consumeGenerationConfig() {
        // Default config.
        var cfg = GenerationConfig()
        // Public mutable field — used by inference service to inject grammar.
        cfg.grammar = "root ::= \"x\""
    }

    // MARK: - Records

    private static func consumeMessageRole() {
        let _: MessageRole = .user
        let _: MessageRole = .assistant
        let _: MessageRole = .system
        // Codable + RawRepresentable: surface used in serialization.
        let _: String = MessageRole.user.rawValue
    }

    private static func consumeChatRecords() {
        let session = ChatSession(
            id: UUID(),
            title: "freeze",
            createdAt: Date(),
            updatedAt: Date(),
            systemPrompt: "",
            selectedModelID: nil,
            selectedEndpointID: nil,
            temperature: nil,
            topP: nil,
            repeatPenalty: nil
        )
        _ = session.id
        _ = session.title
        _ = session.pinnedMessageIDs

        let message = ChatMessage(
            id: UUID(),
            role: .user,
            contentParts: [.text("hi")],
            timestamp: Date(),
            sessionID: session.id
        )
        _ = message.content
        _ = message.hasVisibleContent
    }

    private static func consumeMessagePart() {
        let _: MessagePart = .text("hi")
        let _: MessagePart = .image(data: Data(), mimeType: "image/png")
        // The thinking case carries an optional signature for replay.
        let _: MessagePart = .thinking("reasoning", signature: nil)
    }

    // MARK: - Opt-in protocols

    private static func consumeBackendOptInProtocols() {
        // Existence + name shape of the opt-in protocol surface. Host apps
        // and adapters write `class X: TokenizerVendor`-style declarations
        // against these names.
        //
        // The history-receiver protocols (`ConversationHistoryReceiver` /
        // `StructuredHistoryReceiver` / `ToolCallingHistoryReceiver`) were
        // retired in #2312 — conversation history now travels per-call on
        // `GenerationRuntimeHints.history` rather than through set-then-use
        // instance-state install. The consumer-facing surface is the hints
        // field plus the `[StructuredMessage]` projections below.
        let _: any TokenizerVendor.Type = MockTokenizerVendorBackend.self
        let _: [StructuredMessage] = GenerationRuntimeHints(history: [
            StructuredMessage(role: "user", content: "hi")
        ]).history
        let _: [(role: String, content: String)] = [StructuredMessage(role: "user", content: "hi")].flattenedHistory
        let _: [ToolAwareHistoryEntry] = [StructuredMessage(role: "user", content: "hi")].toolAwareHistory
    }

    // MARK: - Errors

    private static func consumeInferenceErrors() {
        // Public error cases that adapters and runtime code switch over.
        let _: InferenceError = .modelNotFound(path: "x")
        let _: InferenceError = .inferenceFailure("x")
        let _: InferenceError = .alreadyGenerating
        let _: InferenceError = .unsupportedGrammar(reason: "x")
    }

    // MARK: - ManifoldRuntime

    private static func consumeRuntimeInputs() {
        // The canonical turn-input surface (TurnInput / TurnConfig / TurnKind)
        // is exercised throughout the runtime tests; pin the outcome/handle
        // value types here:
        let streamHandle = ConversationStreamHandle()
        let outcome = ConversationTurnOutcome(
            sessionID: UUID(),
            streamHandle: streamHandle,
            assistantMessageID: UUID(),
            assistantMessage: nil,
            reason: .stop,
            error: nil,
            finalText: "done",
            promptTokens: 1,
            completionTokens: 2
        )
        let _: ConversationStreamHandle = outcome.streamHandle
        let _: FinishReason = outcome.reason
        let _: String = outcome.finalText
    }

    // MARK: - ManifoldTestSupport

    private static func consumeMockBackend() {
        let backend = MockInferenceBackend()
        backend.tokensToYield = ["a", "b"]
        backend.isModelLoaded = true
        _ = backend.capabilities
        _ = backend.lastConfig
        _ = backend.loadModelCallCount
    }

    private static func consumeChaosBackend() {
        let _: ChaosBackend = ChaosBackend(mode: .none, tokensToYield: ["x"])
        let _: ChaosBackend = ChaosBackend(mode: .dropMidStream(afterTokens: 1))
        let _: ChaosBackend = ChaosBackend(mode: .slowFirstToken(delay: .milliseconds(10)))
        let _: ChaosBackend = ChaosBackend(mode: .burstThenStall(burstSize: 1, stallDuration: .milliseconds(10)))
        let _: ChaosBackend = ChaosBackend(mode: .networkError(afterTokens: 1))
    }
}
