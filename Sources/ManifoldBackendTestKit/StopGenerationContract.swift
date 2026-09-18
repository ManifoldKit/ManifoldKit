import Foundation
import ManifoldInference

extension BackendContractChecks {
    /// Exercises stop → immediate resend on an already-loaded backend.
    ///
    /// The fixture must keep each generation running after its first content
    /// event. A naturally completed or silent stream is a failed precondition,
    /// never cancellation evidence. Companion packages use this same check
    /// with their hardware fixtures; no model is loaded or reset by the check.
    /// Throws a diagnostic on violation so callers can also test broken fixtures.
    @MainActor
    public static func assertStopGenerationContract(
        backend: any InferenceBackend,
        prompt: String = "Count slowly from one to one hundred, spelling every number.",
        config: GenerationConfig = GenerationConfig(maxOutputTokens: 512),
        timeout: Duration = .seconds(10)
    ) async throws {
        var consumers: [Task<Void, Never>] = []
        do {
            guard backend.isModelLoaded else {
                throw StopContractFailure("fixture must load a model before the cancellation check")
            }
            let first = StopContractObservation()
            let firstStream = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)
            consumers.append(first.consume(firstStream))
            try await first.waitForContent(timeout: timeout)
            guard !first.finished, backend.isGenerating else {
                throw StopContractFailure("first generation was not in flight at stop")
            }

            backend.stopGeneration()
            guard !backend.isGenerating else {
                throw StopContractFailure("isGenerating remained true synchronously after stopGeneration")
            }

            // Do not await the old consumer before starting the successor:
            // doing so hides stale teardown that corrupts successor ownership.
            let second = StopContractObservation()
            let secondStream = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)
            consumers.append(second.consume(secondStream))
            try await first.waitForEnd(timeout: timeout)
            try await second.waitForContent(timeout: timeout)
            guard !second.finished, backend.isGenerating else {
                throw StopContractFailure("successor was not in flight after predecessor termination")
            }
            backend.stopGeneration()
            guard !backend.isGenerating else {
                throw StopContractFailure("successor isGenerating remained true after stopGeneration")
            }
            try await second.waitForEnd(timeout: timeout)
        } catch {
            backend.stopGeneration()
            for consumer in consumers { consumer.cancel() }
            for consumer in consumers { await consumer.value }
            throw error
        }
        for consumer in consumers { await consumer.value }
    }
}

private struct StopContractFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private final class StopContractObservation {
    var hasContent = false
    var finished = false
    var failure: Error?

    func consume(_ stream: GenerationStream) -> Task<Void, Never> {
        Task {
            defer { finished = true }
            do {
                for try await event in stream.events {
                    switch event {
                    case .token(let text), .thinkingToken(let text):
                        if !text.isEmpty { hasContent = true }
                    case .toolCall:
                        hasContent = true
                    default: break
                    }
                }
            } catch {
                failure = error
            }
        }
    }

    func waitForContent(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !hasContent && !finished && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        if let failure { throw failure }
        guard hasContent else {
            throw StopContractFailure("generation produced no content before completion or deadline")
        }
    }

    func waitForEnd(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !finished && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard finished else {
            throw StopContractFailure("cancelled stream did not terminate before deadline")
        }
    }
}
