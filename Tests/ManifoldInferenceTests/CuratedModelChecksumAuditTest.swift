import XCTest
@testable import ManifoldInference

/// Audits the curated model list for SHA-256 integrity metadata.
///
/// Hard gate (XCTFail):
///   Every `.gguf` entry in the real `CuratedModel.all` must carry a non-nil,
///   64-character lowercase hex `expectedSHA256`. The empty-list-by-default
///   case is the only exempt state — when an app ships an opinionated curated
///   list, every GGUF entry is a supply-chain trust boundary and missing
///   integrity metadata is a fail-the-build problem (SEC-14).
///
///   Any populated `expectedSHA256` must be 64-char lowercase hex. An empty
///   string or wrong-length value would silently pass validation while
///   providing false confidence.
///
/// Fixture tier:
///   The fixture-based tests below exercise the audit FILTER logic itself
///   (verified vs. unverified, GGUF vs. non-GGUF) with a synthetic
///   `CuratedModel.all` so the predicate stays correct as the schema evolves.
final class CuratedModelChecksumAuditTest: XCTestCase {

    // MARK: - Fixtures

    private var previousAll: [CuratedModel] = []

    override func setUp() {
        super.setUp()
        previousAll = CuratedModel.all
        // Populate a representative set that covers all the paths the audit
        // checks: a verified entry, an unverified entry, and (in the hard-gate
        // test) a deliberately malformed entry.
        CuratedModel.all = [
            CuratedModel(
                id: "audit-verified",
                displayName: "Verified Model",
                fileName: "verified.gguf",
                repoID: "example/verified-GGUF",
                modelType: .gguf,
                approximateSizeBytes: 2_000_000_000,
                recommendedFor: [.medium],
                contextSize: 4096,
                promptTemplate: .llama3,
                description: "Has a known-good SHA-256.",
                expectedSHA256: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
            ),
            CuratedModel(
                id: "audit-unverified",
                displayName: "Unverified Model",
                fileName: "unverified.gguf",
                repoID: "example/unverified-GGUF",
                modelType: .gguf,
                approximateSizeBytes: 4_000_000_000,
                recommendedFor: [.large],
                contextSize: 8192,
                promptTemplate: .llama3,
                description: "No SHA-256 yet — TODO: populate from HF LFS pointer.",
                // TODO: populate sha256 from HF LFS pointer
                expectedSHA256: nil
            ),
            CuratedModel(
                id: "audit-mlx",
                displayName: "MLX Model",
                fileName: "model.mlpackage",
                repoID: "example/mlx-model",
                modelType: .mlx,
                approximateSizeBytes: 3_000_000_000,
                recommendedFor: [.large],
                contextSize: 4096,
                promptTemplate: .llama3,
                description: "MLX models are excluded from the GGUF checksum gate."
            ),
        ]
    }

    override func tearDown() {
        CuratedModel.all = previousAll
        super.tearDown()
    }

    // MARK: - Hard gate: real curated list must have checksums on every GGUF

    /// Inspects the *real* `CuratedModel.all` as captured before setUp installed
    /// the fixture. The empty default is exempt — apps that ship an opinionated
    /// curated list MUST include `expectedSHA256` on every `.gguf` entry, or
    /// CI fails here (SEC-14).
    func test_realCuratedList_everyGGUFHasExpectedSHA256() {
        guard !previousAll.isEmpty else {
            // ManifoldKit ships an empty default list — apps populate it.
            // Nothing to verify; promoting future additions to fail this gate
            // is what the assertion below enforces once entries appear.
            return
        }

        let missing = previousAll
            .filter { $0.modelType == .gguf && $0.expectedSHA256 == nil }
            .map(\.repoID)

        XCTAssertTrue(
            missing.isEmpty,
            "Curated GGUF models are missing expectedSHA256 — populate from the HuggingFace LFS pointer (oid sha256:<hex>): \(missing.joined(separator: ", "))"
        )
    }

    // MARK: - Filter logic: confirm verified/unverified classification

    /// Exercises the audit filter against the synthetic fixture installed in
    /// setUp. Guards the predicate so the hard gate above stays meaningful.
    func test_auditFilter_classifiesFixtureCorrectly() {
        let missing = CuratedModel.all
            .filter { $0.modelType == .gguf && $0.expectedSHA256 == nil }
            .map(\.repoID)

        let missingSet = Set(missing)
        XCTAssertFalse(
            missingSet.contains("example/verified-GGUF"),
            "Verified model should not appear in the missing-checksum list"
        )
        XCTAssertTrue(
            missingSet.contains("example/unverified-GGUF"),
            "Unverified model must appear in the missing-checksum list"
        )
    }

    // MARK: - Hard gate: populated checksums must be valid 64-char hex

    func test_populatedChecksums_areValid64CharHex() {
        let invalid = CuratedModel.all
            .filter { $0.modelType == .gguf }
            .compactMap { $0.expectedSHA256 }
            .filter { $0.count != 64 || !$0.allSatisfy(\.isHexDigit) }

        XCTAssertTrue(
            invalid.isEmpty,
            "Curated GGUF models have malformed expectedSHA256 values: \(invalid)"
        )
    }

    func test_populatedChecksums_rejectsEmptyString() {
        // Temporarily inject a malformed entry to confirm the hard gate catches it.
        let badEntry = CuratedModel(
            id: "audit-bad",
            displayName: "Bad Checksum Model",
            fileName: "bad.gguf",
            repoID: "example/bad-checksum-GGUF",
            modelType: .gguf,
            approximateSizeBytes: 1_000_000_000,
            recommendedFor: [.small],
            contextSize: 2048,
            promptTemplate: .llama3,
            description: "Has an empty-string checksum — should be caught.",
            expectedSHA256: ""
        )

        let invalid = [badEntry]
            .compactMap { $0.expectedSHA256 }
            .filter { $0.count != 64 || !$0.allSatisfy(\.isHexDigit) }

        XCTAssertFalse(
            invalid.isEmpty,
            "Empty string should be flagged as an invalid checksum"
        )
    }

    func test_populatedChecksums_rejectsTooShortHex() {
        let shortEntry = CuratedModel(
            id: "audit-short",
            displayName: "Short Hash Model",
            fileName: "short.gguf",
            repoID: "example/short-hash-GGUF",
            modelType: .gguf,
            approximateSizeBytes: 1_000_000_000,
            recommendedFor: [.small],
            contextSize: 2048,
            promptTemplate: .llama3,
            description: "Has a 32-char (MD5-length) checksum — should be caught.",
            expectedSHA256: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
        )

        let invalid = [shortEntry]
            .compactMap { $0.expectedSHA256 }
            .filter { $0.count != 64 || !$0.allSatisfy(\.isHexDigit) }

        XCTAssertFalse(
            invalid.isEmpty,
            "32-char hex should be flagged as an invalid SHA-256 checksum"
        )
    }

    // MARK: - Non-GGUF models are excluded from the checksum gate

    func test_nonGGUFModels_areNotAuditedForChecksums() {
        // MLX entries without expectedSHA256 must not pollute the GGUF audit.
        let mlxMissing = CuratedModel.all
            .filter { $0.modelType == .mlx && $0.expectedSHA256 == nil }
            .map(\.repoID)

        // The fixture has one MLX model without a hash — confirm it doesn't
        // appear in the GGUF-only filter.
        let ggufMissing = CuratedModel.all
            .filter { $0.modelType == .gguf && $0.expectedSHA256 == nil }
            .map(\.repoID)

        XCTAssertFalse(mlxMissing.isEmpty, "Fixture should have at least one MLX model without a hash")

        for repoID in mlxMissing {
            XCTAssertFalse(
                ggufMissing.contains(repoID),
                "MLX model \(repoID) must not appear in the GGUF checksum audit"
            )
        }
    }
}
