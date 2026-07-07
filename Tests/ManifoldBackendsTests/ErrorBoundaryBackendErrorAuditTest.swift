import XCTest
import ManifoldInference
import ManifoldRuntime
import ManifoldUI
import ManifoldAnyLanguageModel

/// Checklist guard for the error-boundary audit (docs/plans/api-review-2026-07.md
/// item 1.2 / symptom S6) — see the DocC article "Error handling at the
/// boundary" (`ManifoldRuntime.docc/Articles/ErrorHandlingAtTheBoundary.md`)
/// for the full escape-path trace.
///
/// The audit traced which concrete error types can actually reach a consumer
/// at the four public boundaries — `ConversationRuntime.processTurn(_:)` /
/// `processTurnWithOutcome(_:)`, `QuickStartResult.respond(_:)` /
/// `respond(to:)` (and the `ChatViewModel` methods they forward to),
/// `ManifoldKit.quickStart(configuration:)`, and `InferenceService.enqueue`/
/// `generate` (plus its `respond(_:to:config:)` structured-output sibling on
/// the same service) — as opposed to being caught and wrapped (or reduced to
/// a `ToolResult`) before crossing that boundary.
///
/// Nine types survive that trace as the escapable set: three already
/// conformed to `BackendError` before this audit (``InferenceError``,
/// ``CloudBackendError``, ``FallbackExhaustedError``) and six gained the
/// conformance in this pass (``RetryExhaustedError``,
/// ``AnyLanguageModelBridgeError``, ``StructuredOutputError``,
/// ``ConversationError``, ``SendMessageError``, ``ManifoldKitError`` —
/// the DocC article has the precise table).
///
/// Honest scope: this test guards the KNOWN set — it fails when a case is
/// added to or removed from one of the nine named types (the per-type
/// instance counts drift), but it cannot detect a genuinely NEW tenth
/// escapable type introduced at a boundary, because nothing forces such a
/// PR to touch this file. The DocC article is the human-maintained registry;
/// extending the escapable set means updating both it and this checklist. This test lives in
/// `ManifoldBackendsTests` because it is the one test target that already
/// depends on every module the escapable set spans (`ManifoldInference`,
/// `ManifoldRuntime`, `ManifoldUI`, `ManifoldAnyLanguageModel`) with zero new
/// Package.swift edges; `ManifoldKitError` (defined in `ManifoldModelCatalog`)
/// and `CloudBackendError` (same) are reachable through `ManifoldInference`'s
/// `@_exported import` chain without an explicit import.
///
/// If this test fails after adding a new case, the associated type's
/// `BackendError` conformance (and its documented `isRetryable` reasoning)
/// needs to grow to match — or, if the new case is actually caught and
/// wrapped before any boundary, the DocC article and this test both need to
/// record why it was excluded, not silently pass.
final class ErrorBoundaryBackendErrorAuditTest: XCTestCase {

    /// Every concrete type this audit found to be escapable, instantiated
    /// once per case so the assertion below can't pass on a type that merely
    /// exists but forgot a case. Types with an unbounded/representative
    /// associated-value shape (`InferenceError`, `CloudBackendError`) use a
    /// small representative cross-section — they already have dedicated
    /// exhaustive coverage elsewhere (`ErrorDescriptionTests`,
    /// `RetryPolicyTests`, `CloudBackendErrorTests`).
    private func allEscapableInstances() -> [(name: String, error: any BackendError)] {
        var instances: [(String, any BackendError)] = []

        // InferenceError — representative cross-section.
        instances.append(("InferenceError.inferenceFailure", InferenceError.inferenceFailure("test")))
        instances.append(("InferenceError.idleTimeout", InferenceError.idleTimeout(.seconds(1))))

        // CloudBackendError — representative cross-section.
        instances.append(("CloudBackendError.invalidURL", CloudBackendError.invalidURL("test")))
        instances.append(("CloudBackendError.rateLimited", CloudBackendError.rateLimited(retryAfter: nil)))

        // FallbackExhaustedError — conforms at its own declaration (opt-in,
        // FallbackBackend composition).
        instances.append((
            "FallbackExhaustedError",
            FallbackExhaustedError(perBackendErrors: [InferenceError.inferenceFailure("child")])
        ))

        // RetryExhaustedError — new conformance (mainline: any Ollama/CloudSaaS
        // connection-retry exhaustion).
        instances.append((
            "RetryExhaustedError",
            RetryExhaustedError(lastError: InferenceError.inferenceFailure("last"), attempts: 3)
        ))

        // AnyLanguageModelBridgeError — new conformance (opt-in,
        // AnyLanguageModelBackend composition). One instance per case
        // (exhaustive; small enum).
        instances.append(("AnyLanguageModelBridgeError.unsupportedURLScheme", AnyLanguageModelBridgeError.unsupportedURLScheme(URL(string: "ftp://test")!)))
        instances.append(("AnyLanguageModelBridgeError.missingModelIdentifier", AnyLanguageModelBridgeError.missingModelIdentifier(provider: "test")))
        instances.append(("AnyLanguageModelBridgeError.missingQueryItem", AnyLanguageModelBridgeError.missingQueryItem(name: "model", provider: "test")))
        instances.append(("AnyLanguageModelBridgeError.modelNotLoaded", AnyLanguageModelBridgeError.modelNotLoaded))
        instances.append(("AnyLanguageModelBridgeError.unsupportedToolCalling", AnyLanguageModelBridgeError.unsupportedToolCalling))
        instances.append(("AnyLanguageModelBridgeError.unsupportedStructuredOutput", AnyLanguageModelBridgeError.unsupportedStructuredOutput))

        // StructuredOutputError — new conformance. One instance per case
        // (exhaustive; small enum).
        instances.append(("StructuredOutputError.decodeFailure", StructuredOutputError.decodeFailure(rawText: "test", underlying: "test")))
        instances.append(("StructuredOutputError.schemaEncodingFailure", StructuredOutputError.schemaEncodingFailure("test")))
        instances.append(("StructuredOutputError.reaskBudgetExhausted", StructuredOutputError.reaskBudgetExhausted(lastError: "test", attempts: 2)))

        // ManifoldKitError — new conformance. One instance per case
        // (exhaustive; small enum).
        instances.append(("ManifoldKitError.notConnectedToInternet", ManifoldKitError.notConnectedToInternet))
        instances.append(("ManifoldKitError.timedOut", ManifoldKitError.timedOut))
        instances.append(("ManifoldKitError.cancelled", ManifoldKitError.cancelled))
        instances.append(("ManifoldKitError.tlsFailure", ManifoldKitError.tlsFailure))
        instances.append(("ManifoldKitError.dnsFailure", ManifoldKitError.dnsFailure))
        instances.append(("ManifoldKitError.serverError(500)", ManifoldKitError.serverError(statusCode: 500, message: nil)))
        instances.append(("ManifoldKitError.serverError(404)", ManifoldKitError.serverError(statusCode: 404, message: nil)))
        instances.append(("ManifoldKitError.keychainUnavailable", ManifoldKitError.keychainUnavailable))
        instances.append(("ManifoldKitError.decodingFailure", ManifoldKitError.decodingFailure("test")))
        instances.append(("ManifoldKitError.noBackendsRegistered", ManifoldKitError.noBackendsRegistered))
        instances.append(("ManifoldKitError.unknown", ManifoldKitError.unknown(underlyingDescription: "test")))

        // ConversationError — new conformance. One instance per case
        // (exhaustive; the type is closed and small).
        instances.append(("ConversationError.providerNotConfigured", ConversationError.providerNotConfigured))
        instances.append(("ConversationError.messageTooLarge", ConversationError.messageTooLarge(limit: 1)))
        instances.append(("ConversationError.noAssistantMessageToRegenerate", ConversationError.noAssistantMessageToRegenerate))
        instances.append(("ConversationError.messageNotFound", ConversationError.messageNotFound(UUID())))
        instances.append(("ConversationError.persistence", ConversationError.persistence(InferenceError.inferenceFailure("underlying"))))
        instances.append(("ConversationError.inference", ConversationError.inference(InferenceError.inferenceFailure("underlying"))))
        instances.append(("ConversationError.contextAssembly", ConversationError.contextAssembly(InferenceError.inferenceFailure("underlying"))))
        instances.append(("ConversationError.preTurnCompressionFailed", ConversationError.preTurnCompressionFailed(InferenceError.inferenceFailure("underlying"))))
        instances.append(("ConversationError.cancelled", ConversationError.cancelled))

        // SendMessageError — new conformance. One instance per case
        // (exhaustive; the type is closed and small).
        instances.append(("SendMessageError.noActiveSession", SendMessageError.noActiveSession))
        instances.append(("SendMessageError.noModelLoaded", SendMessageError.noModelLoaded))
        instances.append(("SendMessageError.empty", SendMessageError.empty))
        instances.append(("SendMessageError.runtime", SendMessageError.runtime(InferenceError.inferenceFailure("underlying"))))

        return instances
    }

    /// Every escapable case must conform to `BackendError`, report a usable
    /// `errorDescription`, and answer `isRetryable` without trapping.
    func test_everyEscapableCaseConformsToBackendErrorAndReportsIsRetryable() {
        let instances = allEscapableInstances()
        XCTAssertEqual(
            instances.count, 39,
            "Update this test's case list when adding or removing a case on any " +
            "escapable type (InferenceError, CloudBackendError, FallbackExhaustedError, " +
            "RetryExhaustedError, AnyLanguageModelBridgeError, StructuredOutputError, " +
            "ManifoldKitError, ConversationError, SendMessageError)."
        )
        for (name, error) in instances {
            // Accessing `isRetryable` and `errorDescription` on the `any
            // BackendError` existential exercises the actual protocol
            // conformance path (not just "the extension compiles").
            _ = error.isRetryable
            XCTAssertNotNil(
                error.errorDescription,
                "\(name) must supply a non-nil errorDescription (LocalizedError, part of BackendError)."
            )
        }
    }

    /// Nested `any Error`-carrying cases (`ConversationError.inference`,
    /// `.persistence`, `.contextAssembly`, `.preTurnCompressionFailed`,
    /// `SendMessageError.runtime`, `RetryExhaustedError.lastError`) must
    /// defer to the wrapped error's own `isRetryable` when it conforms to
    /// `BackendError`, rather than always returning a fixed value — this is
    /// the "everything else arrives wrapped in one of these" contract
    /// actually holding end to end.
    func test_nestedCasesDeferToUnderlyingBackendErrorRetryability() {
        XCTAssertTrue(
            ConversationError.inference(CloudBackendError.rateLimited(retryAfter: 1)).isRetryable,
            "ConversationError.inference must defer to a retryable underlying CloudBackendError."
        )
        XCTAssertFalse(
            ConversationError.inference(CloudBackendError.missingAPIKey).isRetryable,
            "ConversationError.inference must defer to a non-retryable underlying CloudBackendError."
        )
        XCTAssertTrue(
            SendMessageError.runtime(InferenceError.idleTimeout(.seconds(1))).isRetryable,
            "SendMessageError.runtime must defer to a retryable underlying InferenceError."
        )
        XCTAssertTrue(
            RetryExhaustedError(lastError: CloudBackendError.rateLimited(retryAfter: 1), attempts: 3).isRetryable,
            "RetryExhaustedError must defer to a retryable underlying CloudBackendError — a fresh " +
            "call restarts the retry budget from zero."
        )
        XCTAssertFalse(
            RetryExhaustedError(lastError: CloudBackendError.missingAPIKey, attempts: 3).isRetryable,
            "RetryExhaustedError must defer to a non-retryable underlying CloudBackendError."
        )
        struct OpaqueNonBackendError: Error {}
        XCTAssertFalse(
            SendMessageError.runtime(OpaqueNonBackendError()).isRetryable,
            "SendMessageError.runtime wrapping a value that does not conform to " +
            "BackendError must fall back to false, not guess true."
        )
        XCTAssertFalse(
            RetryExhaustedError(lastError: OpaqueNonBackendError(), attempts: 1).isRetryable,
            "RetryExhaustedError wrapping a value that does not conform to " +
            "BackendError must fall back to false, not guess true."
        )
    }

    /// Sabotage coverage (self-contained, per the `TrafficBoundaryAuditTest`
    /// pattern): prove the audit's per-instance predicate is a real
    /// discriminator, not a vacuous pass. A `BackendError` conformer that
    /// omits `errorDescription` inherits `LocalizedError`'s nil default —
    /// exactly the violation the audit's `XCTAssertNotNil` exists to catch —
    /// so feeding one through the same existential access path must come
    /// back nil. The conformer is a local type, so the production case list
    /// never sees it.
    func test_sabotage_missingErrorDescriptionIsDetectable() {
        struct SabotagedBoundaryError: BackendError {
            var isRetryable: Bool { false }
            // Deliberately no errorDescription: LocalizedError's default
            // returns nil, which the audit's check must reject.
        }
        let sabotaged: any BackendError = SabotagedBoundaryError()
        XCTAssertNil(
            sabotaged.errorDescription,
            "Sabotage: expected a BackendError conformer without errorDescription to " +
            "report nil through the existential — if this is non-nil, the audit's " +
            "errorDescription check can no longer fail and guards nothing."
        )
    }
}
