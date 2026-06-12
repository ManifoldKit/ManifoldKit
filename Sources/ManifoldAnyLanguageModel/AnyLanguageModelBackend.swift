import ManifoldInference
import Foundation
import os

import AnyLanguageModel

/// Thin `InferenceBackend` adapter for HuggingFace's AnyLanguageModel session layer.
///
/// This bridge is intentionally scoped to provider coverage, not operational parity.
/// Requests routed through it do **not** inherit ManifoldKit's certificate pinning, retry
/// strategy, circuit breaker, or latest-wins cancellation guarantees because AnyLanguageModel
/// owns those concerns internally. `stopGeneration()` maps to `Task.cancel()`, so stop
/// promptness depends on AnyLanguageModel's implementation. `unloadModel()` drops the active
/// descriptor and session references, but AnyLanguageModel defines the actual session teardown.
public final class AnyLanguageModelBackend: @unchecked Sendable, InferenceBackend {
    private struct State {
        var descriptor: AnyLanguageModelDescriptor?
        var generationTask: Task<Void, Never>?
        var activeSession: LanguageModelSession?
        var capabilities: BackendCapabilities = AnyLanguageModelBridgeCapabilities.remote()
        var isGenerating = false
    }

    private let resolver: AnyLanguageModelResolver
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(resolver: @escaping AnyLanguageModelResolver = AnyLanguageModelURLResolver.resolve) {
        self.resolver = resolver
    }

    public var isModelLoaded: Bool {
        state.withLock { $0.descriptor != nil }
    }

    public var isGenerating: Bool {
        state.withLock { $0.isGenerating }
    }

    public var capabilities: BackendCapabilities {
        state.withLock { $0.capabilities }
    }

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        let descriptor = try resolver(url)
        state.withLock { state in
            state.descriptor = descriptor
            state.activeSession = nil
            state.capabilities = BackendCapabilities(
                supportedParameters: descriptor.capabilities.supportedParameters,
                maxContextTokens: Int32(plan.effectiveContextSize),
                requiresPromptTemplate: descriptor.capabilities.requiresPromptTemplate,
                supportsSystemPrompt: descriptor.capabilities.supportsSystemPrompt,
                supportsToolCalling: descriptor.capabilities.supportsToolCalling,
                supportsStructuredOutput: descriptor.capabilities.supportsStructuredOutput,
                supportsNativeJSONMode: descriptor.capabilities.supportsNativeJSONMode,
                cancellationStyle: descriptor.capabilities.cancellationStyle,
                supportsTokenCounting: descriptor.capabilities.supportsTokenCounting,
                memoryStrategy: descriptor.capabilities.memoryStrategy,
                maxOutputTokens: descriptor.capabilities.maxOutputTokens,
                supportsStreaming: descriptor.capabilities.supportsStreaming,
                isRemote: descriptor.capabilities.isRemote,
                supportsKVCachePersistence: descriptor.capabilities.supportsKVCachePersistence,
                supportsGrammarConstrainedSampling: descriptor.capabilities.supportsGrammarConstrainedSampling,
                supportsThinking: descriptor.capabilities.supportsThinking,
                streamsToolCallArguments: descriptor.capabilities.streamsToolCallArguments,
                supportsParallelToolCalls: descriptor.capabilities.supportsParallelToolCalls
            )
        }
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        if !config.tools.isEmpty {
            throw AnyLanguageModelBridgeError.unsupportedToolCalling
        }
        if config.jsonMode {
            throw AnyLanguageModelBridgeError.unsupportedStructuredOutput
        }
        if config.grammar != nil {
            throw InferenceError.unsupportedGrammar(reason: "AnyLanguageModel bridge does not expose grammar-constrained sampling.")
        }
        if state.withLock({ $0.isGenerating }) {
            throw InferenceError.alreadyGenerating
        }
        guard let descriptor = state.withLock({ $0.descriptor }) else {
            throw AnyLanguageModelBridgeError.modelNotLoaded
        }

        let session: LanguageModelSession
        if let systemPrompt, !systemPrompt.isEmpty {
            session = LanguageModelSession(model: descriptor.model, instructions: systemPrompt)
        } else {
            session = LanguageModelSession(model: descriptor.model)
        }

        let upstream = session.streamResponse(to: prompt, options: generationOptions(from: config))
        let rawStream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            let task = Task {
                state.withLock { state in
                    state.isGenerating = true
                    state.activeSession = session
                }
                defer {
                    state.withLock { state in
                        state.isGenerating = false
                        state.generationTask = nil
                        state.activeSession = nil
                    }
                }

                do {
                    for try await event in AnyLanguageModelStreamBridge.makeEvents(from: upstream) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            state.withLock { $0.generationTask = task }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        return GenerationStream(rawStream)
    }

    public func stopGeneration() {
        let task = state.withLock { state -> Task<Void, Never>? in
            let task = state.generationTask
            state.generationTask = nil
            state.activeSession = nil
            state.isGenerating = false
            return task
        }
        task?.cancel()
    }

    public func unloadModel() {
        stopGeneration()
        state.withLock { state in
            state.descriptor = nil
            state.activeSession = nil
        }
    }

    private func generationOptions(from config: GenerationConfig) -> GenerationOptions {
        GenerationOptions(
            sampling: samplingMode(from: config),
            temperature: Double(config.temperature),
            maximumResponseTokens: config.maxOutputTokens
        )
    }

    private func samplingMode(from config: GenerationConfig) -> GenerationOptions.SamplingMode? {
        if config.temperature <= 0 {
            return .greedy
        }
        let topP = Double(max(0.0, min(config.topP, 1.0)))
        if topP > 0, topP < 1 {
            return .random(probabilityThreshold: topP, seed: config.seed)
        }
        if let seed = config.seed {
            return .random(top: Int(config.topK ?? 40), seed: seed)
        }
        return nil
    }
}
