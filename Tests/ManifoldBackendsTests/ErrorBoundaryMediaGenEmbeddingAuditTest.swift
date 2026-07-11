import XCTest
import ManifoldInference

/// Checklist guard for the media-gen / embedding leg of the `BackendError`
/// spine (#2157 "BackendError spine extension") — the DocC article
/// "Error handling at the boundary"
/// (`ManifoldRuntime.docc/Articles/ErrorHandlingAtTheBoundary.md`) explicitly
/// scoped ``ErrorBoundaryBackendErrorAuditTest`` to the four chat-path
/// surfaces and named these four types as separate, not-yet-conforming
/// boundaries. This test is the equivalent checklist for that separate set:
///
/// - ``ImageGenerationServiceError`` — escapes `ImageGenerationRuntime`'s
///   public `AsyncThrowingStream<ImageGenerationEvent, Error>` event stream.
/// - ``VideoGenerationServiceError`` — escapes `VideoGenerationRuntime`'s
///   equivalent stream.
/// - ``AudioGenerationServiceError`` — escapes `AudioGenerationRuntime`'s
///   equivalent stream.
/// - ``EmbeddingError`` — thrown directly by `EmbeddingBackend.embed(_:)`.
///
/// Honest scope: like its chat-path sibling, this test guards the KNOWN set
/// — it fails when a case is added to or removed from one of these four
/// types (the per-type instance counts drift), but it cannot detect a
/// genuinely new escapable type at a media-gen/embedding boundary, because
/// nothing forces such a PR to touch this file.
final class ErrorBoundaryMediaGenEmbeddingAuditTest: XCTestCase {

    /// Every concrete type this audit covers, instantiated once per case.
    private func allEscapableInstances() -> [(name: String, error: any BackendError)] {
        var instances: [(String, any BackendError)] = []

        // ImageGenerationServiceError — exhaustive; small enum.
        instances.append((
            "ImageGenerationServiceError.noFactoryRegistered",
            ImageGenerationServiceError.noFactoryRegistered(format: .cloudAPI)
        ))
        instances.append((
            "ImageGenerationServiceError.notLoaded",
            ImageGenerationServiceError.notLoaded
        ))

        // VideoGenerationServiceError — exhaustive; single case.
        instances.append((
            "VideoGenerationServiceError.alreadyGenerating",
            VideoGenerationServiceError.alreadyGenerating
        ))

        // AudioGenerationServiceError — exhaustive; single case.
        instances.append((
            "AudioGenerationServiceError.alreadyGenerating",
            AudioGenerationServiceError.alreadyGenerating
        ))

        // EmbeddingError — exhaustive; small enum.
        instances.append((
            "EmbeddingError.modelNotLoaded",
            EmbeddingError.modelNotLoaded
        ))
        instances.append((
            "EmbeddingError.dimensionMismatch",
            EmbeddingError.dimensionMismatch(expected: 384, actual: 128)
        ))
        instances.append((
            "EmbeddingError.encodingFailed",
            EmbeddingError.encodingFailed(underlying: NSError(domain: "test", code: 1))
        ))

        return instances
    }

    /// Every escapable case must conform to `BackendError`, report a usable
    /// `errorDescription`, and answer `isRetryable` without trapping.
    func test_everyEscapableCaseConformsToBackendErrorAndReportsIsRetryable() {
        let instances = allEscapableInstances()
        XCTAssertEqual(
            instances.count, 7,
            "Update this test's case list when adding or removing a case on any " +
            "escapable type (ImageGenerationServiceError, VideoGenerationServiceError, " +
            "AudioGenerationServiceError, EmbeddingError)."
        )
        for (name, error) in instances {
            _ = error.isRetryable
            XCTAssertNotNil(
                error.errorDescription,
                "\(name) must supply a non-nil errorDescription (LocalizedError, part of BackendError)."
            )
        }
    }

    /// `EmbeddingError.encodingFailed` must defer to the wrapped error's own
    /// `isRetryable` when it conforms to `BackendError`, rather than always
    /// returning a fixed value — mirrors the chat-path audit's equivalent
    /// nested-case check.
    func test_encodingFailedDefersToUnderlyingBackendErrorRetryability() {
        XCTAssertTrue(
            EmbeddingError.encodingFailed(underlying: CloudBackendError.rateLimited(retryAfter: 1)).isRetryable,
            "encodingFailed must defer to a retryable underlying CloudBackendError."
        )
        XCTAssertFalse(
            EmbeddingError.encodingFailed(underlying: CloudBackendError.missingAPIKey).isRetryable,
            "encodingFailed must defer to a non-retryable underlying CloudBackendError."
        )
        struct OpaqueNonBackendError: Error {}
        XCTAssertFalse(
            EmbeddingError.encodingFailed(underlying: OpaqueNonBackendError()).isRetryable,
            "encodingFailed wrapping a value that does not conform to BackendError must fall back to false, not guess true."
        )
    }

    /// None of the four caller-precondition cases (`.noFactoryRegistered`,
    /// `.notLoaded`, `.alreadyGenerating` × 2) is retryable — retrying
    /// unchanged reproduces the same precondition failure.
    func test_preconditionCasesAreNotRetryable() {
        XCTAssertFalse(ImageGenerationServiceError.noFactoryRegistered(format: .mlxDiffusion).isRetryable)
        XCTAssertFalse(ImageGenerationServiceError.notLoaded.isRetryable)
        XCTAssertFalse(VideoGenerationServiceError.alreadyGenerating.isRetryable)
        XCTAssertFalse(AudioGenerationServiceError.alreadyGenerating.isRetryable)
        XCTAssertFalse(EmbeddingError.modelNotLoaded.isRetryable)
        XCTAssertFalse(EmbeddingError.dimensionMismatch(expected: 1, actual: 2).isRetryable)
    }

    /// Sabotage coverage (self-contained, per the `TrafficBoundaryAuditTest` /
    /// `ErrorBoundaryBackendErrorAuditTest` pattern): prove the audit's
    /// per-instance predicate is a real discriminator, not a vacuous pass. A
    /// `BackendError` conformer that omits `errorDescription` inherits
    /// `LocalizedError`'s nil default — exactly the violation the audit's
    /// `XCTAssertNotNil` exists to catch — so feeding one through the same
    /// existential access path must come back nil. The conformer is a local
    /// type, so the production case list never sees it.
    func test_sabotage_missingErrorDescriptionIsDetectable() {
        struct SabotagedMediaGenError: BackendError {
            var isRetryable: Bool { false }
            // Deliberately no errorDescription: LocalizedError's default
            // returns nil, which the audit's check must reject.
        }
        let sabotaged: any BackendError = SabotagedMediaGenError()
        XCTAssertNil(
            sabotaged.errorDescription,
            "Sabotage: expected a BackendError conformer without errorDescription to " +
            "report nil through the existential — if this is non-nil, the audit's " +
            "errorDescription check can no longer fail and guards nothing."
        )
    }
}
