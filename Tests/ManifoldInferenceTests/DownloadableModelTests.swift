import XCTest
@testable import ManifoldInference

final class DownloadableModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CuratedModel.all = [
            CuratedModel(
                id: "test-phi",
                displayName: "Phi-3.1 Mini Q4",
                fileName: "phi-3.1-mini-q4.gguf",
                repoID: "bartowski/Phi-3.1-mini-4k-instruct-GGUF",
                modelType: .gguf,
                approximateSizeBytes: 2_200_000_000,
                recommendedFor: [.small, .medium, .large, .xlarge],
                contextSize: 4096,
                promptTemplate: .phi,
                description: "Phi-3.1 Mini 4-bit quantized model"
            )
        ]
    }

    override func tearDown() {
        CuratedModel.all = []
        super.tearDown()
    }

    // MARK: - Init from CuratedModel

    func test_initFromCuratedModel_setsAllProperties() {
        // Safe to force-unwrap: curated list is non-empty by design.
        // swiftlint:disable:next force_unwrapping
        let curated = CuratedModel.all.first!
        let model = DownloadableModel(from: curated)

        XCTAssertEqual(model.repoID, curated.repoID)
        XCTAssertEqual(model.fileName, curated.fileName)
        XCTAssertEqual(model.displayName, curated.displayName)
        XCTAssertEqual(model.modelType, curated.modelType)
        XCTAssertEqual(model.sizeBytes, curated.approximateSizeBytes)
        XCTAssertNil(model.downloads, "Curated models should have nil downloads count")
        XCTAssertTrue(model.isCurated, "Model from curated source should be marked curated")
        XCTAssertEqual(model.promptTemplate, curated.promptTemplate)
        XCTAssertEqual(model.description, curated.description)
    }

    func test_initFromCuratedModel_idFormat() {
        // Safe to force-unwrap: curated list is non-empty by design.
        // swiftlint:disable:next force_unwrapping
        let curated = CuratedModel.all.first!
        let model = DownloadableModel(from: curated)

        let expectedID = "\(curated.repoID)/\(curated.fileName)"
        XCTAssertEqual(model.id, expectedID, "ID should be repoID/fileName")

        // Verify the ID contains exactly one separator between repo and file.
        let components = model.id.components(separatedBy: "/")
        XCTAssertGreaterThanOrEqual(
            components.count, 3,
            "ID should have at least namespace/repo/fileName parts"
        )
    }

    func test_initFromCuratedModel_mlxId_doesNotDoubleRepoPath() {
        // MLX curated models use just the repo name as fileName (e.g. "Phi-4-mini-instruct-4bit"),
        // NOT the full "org/repo" path. If fileName == repoID the computed id becomes
        // "org/repo/org/repo" — a doubled path that corrupts download tracking keys.
        let curated = CuratedModel(
            id: "test-mlx",
            displayName: "Test MLX",
            fileName: "MyRepo",
            repoID: "myorg/MyRepo",
            modelType: .mlx,
            approximateSizeBytes: 1_000_000_000,
            recommendedFor: [.large],
            contextSize: 4096,
            promptTemplate: .chatML,
            description: "Test"
        )

        let model = DownloadableModel(from: curated)

        XCTAssertEqual(model.id, "myorg/MyRepo/MyRepo",
                       "id must be repoID/fileName — not doubled")
        XCTAssertFalse(model.id.contains("myorg/MyRepo/myorg/MyRepo"),
                       "fileName must not repeat the org/repo prefix; that doubles the id")

        // Sabotage check: set fileName: "myorg/MyRepo" above and the second assertion fails.
    }

    // MARK: - Size Formatting

    func test_sizeFormatted_formatsCorrectly() {
        let model = DownloadableModel(
            repoID: "test/repo",
            fileName: "test.gguf",
            displayName: "Test",
            modelType: .gguf,
            sizeBytes: 4_100_000_000
        )

        let formatted = model.sizeFormatted
        XCTAssertFalse(formatted.isEmpty, "Formatted size should not be empty")
        // ByteCountFormatter with .file style should produce something like "4.1 GB".
        XCTAssertTrue(
            formatted.contains("GB") || formatted.contains("Go"),
            "4.1 billion bytes should format as GB (got: \(formatted))"
        )
    }

    // MARK: - Memberwise Init Defaults

    func test_memberwise_setsIsCuratedFalse() {
        let model = DownloadableModel(
            repoID: "test/repo",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 1_000_000
        )

        XCTAssertFalse(model.isCurated, "Memberwise init should default isCurated to false")
        XCTAssertNil(model.downloads, "Memberwise init should default downloads to nil")
        XCTAssertNil(model.promptTemplate, "Memberwise init should default promptTemplate to nil")
        XCTAssertNil(model.description, "Memberwise init should default description to nil")
    }

    // MARK: - Quantization

    func test_quantization_Q4KM_extractedCorrectly() {
        let model = DownloadableModel(
            repoID: "bartowski/Llama-3-8B-GGUF",
            fileName: "Llama-3-8B-Q4_K_M.gguf",
            displayName: "Llama 3 8B Q4_K_M",
            modelType: .gguf,
            sizeBytes: 4_661_000_000
        )

        XCTAssertEqual(model.quantization, "Q4_K_M")
    }

    func test_quantization_Q8_0_extractedCorrectly() {
        let model = DownloadableModel(
            repoID: "bartowski/Mistral-7B-GGUF",
            fileName: "Mistral-7B-Q8_0.gguf",
            displayName: "Mistral 7B Q8_0",
            modelType: .gguf,
            sizeBytes: 7_700_000_000
        )

        XCTAssertEqual(model.quantization, "Q8_0")
    }

    func test_quantization_IQ2XS_extractedCorrectly() {
        let model = DownloadableModel(
            repoID: "bartowski/some-model-GGUF",
            fileName: "model-IQ2_XS.gguf",
            displayName: "Some Model IQ2_XS",
            modelType: .gguf,
            sizeBytes: 1_600_000_000
        )

        XCTAssertEqual(model.quantization, "IQ2_XS")
    }

    func test_quantization_F16_extractedCorrectly() {
        let model = DownloadableModel(
            repoID: "bartowski/some-model-GGUF",
            fileName: "model-F16.gguf",
            displayName: "Some Model F16",
            modelType: .gguf,
            sizeBytes: 14_000_000_000
        )

        XCTAssertEqual(model.quantization, "F16")
    }

    func test_quantization_BF16_extractedCorrectly() {
        let model = DownloadableModel(
            repoID: "bartowski/some-model-GGUF",
            fileName: "model-BF16.gguf",
            displayName: "Some Model BF16",
            modelType: .gguf,
            sizeBytes: 14_000_000_000
        )

        XCTAssertEqual(model.quantization, "BF16")
    }

    func test_quantization_nilForMLXModel() {
        let model = DownloadableModel(
            repoID: "mlx-community/Llama-3-8B-mlx",
            fileName: "Llama-3-8B-Q4_K_M",
            displayName: "Llama 3 8B MLX",
            modelType: .mlx,
            sizeBytes: 4_661_000_000
        )

        XCTAssertNil(model.quantization, "MLX models should always return nil for quantization")
    }

    func test_quantization_nilWhenNoQuantInFilename() {
        let model = DownloadableModel(
            repoID: "bartowski/some-model-GGUF",
            fileName: "model.gguf",
            displayName: "Some Model",
            modelType: .gguf,
            sizeBytes: 1_000_000_000
        )

        XCTAssertNil(model.quantization, "Filename with no quant tag should return nil")
    }

    func test_quantization_dotSeparated_extractedCorrectly() {
        let model = DownloadableModel(
            repoID: "bartowski/some-model-GGUF",
            fileName: "model.Q4_K_M.gguf",
            displayName: "Some Model Q4_K_M",
            modelType: .gguf,
            sizeBytes: 4_661_000_000
        )

        XCTAssertEqual(model.quantization, "Q4_K_M")
    }

    func test_quantization_dashSeparated_extractedCorrectly() {
        let model = DownloadableModel(
            repoID: "bartowski/some-model-GGUF",
            fileName: "model-Q4_K_M.gguf",
            displayName: "Some Model Q4_K_M",
            modelType: .gguf,
            sizeBytes: 4_661_000_000
        )

        XCTAssertEqual(model.quantization, "Q4_K_M")
    }

    func test_quantization_IQ2_XXS_extractedCorrectly() {
        let model = DownloadableModel(
            repoID: "bartowski/some-model-GGUF",
            fileName: "m.IQ2_XXS.gguf",
            displayName: "Some Model IQ2_XXS",
            modelType: .gguf,
            sizeBytes: 1_600_000_000
        )

        XCTAssertEqual(model.quantization, "IQ2_XXS")
    }

    func test_quantization_nilForUnknownTag() {
        // Pattern requires the (Q|IQ|F|BF) prefix; arbitrary alphanumerics must not match.
        let model = DownloadableModel(
            repoID: "bartowski/some-model-GGUF",
            fileName: "foo.X99.gguf",
            displayName: "Foo",
            modelType: .gguf,
            sizeBytes: 1_000_000_000
        )

        XCTAssertNil(model.quantization, "Non-quant alphanumeric tags should not match")
    }

    // MARK: - ReDoS Hardening
    //
    // The quantization regex has a repeated `(?:_[A-Z0-9]+)` group. Before the fix this
    // was unbounded (`*`) which — combined with the trailing literal `.` — enabled
    // catastrophic backtracking on pathological input (many `_LETTERS` groups followed
    // by a non-matching character before the final dot). The fix bounds the repetition
    // to {0,5} and caps the input length to 128 chars so hostile filenames cannot
    // stall the caller.

    func test_quantization_pathologicalInput_completesQuickly_andReturnsNil() {
        // ~1000 chars: "_AAAA" × 200 after the Q4 prefix, then a non-matching `X` before `.gguf`.
        // With the original unbounded pattern this pegs the CPU; with the fix it is bounded.
        let suffix = String(repeating: "_AAAA", count: 200)
        let hostileName = "model_Q4" + suffix + "X.gguf"

        let model = DownloadableModel(
            repoID: "attacker/repo",
            fileName: hostileName,
            displayName: "Pathological",
            modelType: .gguf,
            sizeBytes: 1
        )

        // Monotonic clock instead of wall-clock `Date()` — the latter is subject
        // to system clock adjustments which would give a spurious negative
        // elapsed reading.
        let start = DispatchTime.now()
        let result = model.quantization
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let elapsed = Double(elapsedNanos) / 1_000_000_000

        // Budget: 200ms. The fix makes this path return in microseconds; the
        // unbounded pattern on the sabotage check blows through seconds. 200ms
        // rather than 50ms gives slack for CI variance (10x billed macOS
        // runners are noticeably slower than local) while still catching any
        // regression that puts us anywhere near the original pathological
        // profile.
        XCTAssertLessThan(
            elapsed, 0.2,
            "Quantization extraction must complete in <200ms on hostile input (took \(elapsed)s)"
        )
        // Input is clipped to 128 chars; within that window there is no trailing `.`
        // closing a Q-prefixed run, so the match must fail.
        XCTAssertNil(result, "Pathological input must not yield a spurious quant tag")
    }

    func test_quantization_inputLongerThan128Chars_isClipped() {
        // Place a valid-looking quant tag *after* the 128-char cutoff. Because we apply
        // the regex to a prefix-bounded string, it must not be returned.
        let padding = String(repeating: "a", count: 200)
        let fileName = padding + "-Q4_K_M.gguf"

        let model = DownloadableModel(
            repoID: "attacker/repo",
            fileName: fileName,
            displayName: "Long",
            modelType: .gguf,
            sizeBytes: 1
        )

        XCTAssertNil(
            model.quantization,
            "Quant tags beyond the 128-char input cap must be ignored"
        )
    }
    // MARK: - File Name Validator

    func test_validate_acceptsPlainGGUFName() {
        XCTAssertNoThrow(try DownloadableModel.validate(fileName: "model.gguf"))
    }

    func test_validate_acceptsDashedGGUFName() {
        XCTAssertNoThrow(try DownloadableModel.validate(fileName: "mistral-7b-q4_k_m.gguf"))
    }

    func test_validate_acceptsDotSeparatedQuantName() {
        XCTAssertNoThrow(try DownloadableModel.validate(fileName: "model.Q4_K_M.gguf"))
    }

    func test_validate_acceptsMLXNamespacedName() {
        // Curated MLX models use this namespace/name form — it must remain legal.
        XCTAssertNoThrow(
            try DownloadableModel.validate(fileName: "mlx-community/Phi-4-mini-instruct-4bit")
        )
    }

    func test_validate_rejectsEmpty() {
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "")) { error in
            XCTAssertEqual(error as? FileNameError, .empty)
        }
    }

    func test_validate_rejectsParentTraversal() {
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "../secret")) { error in
            XCTAssertEqual(error as? FileNameError, .pathTraversal)
        }
    }

    func test_validate_rejectsDeepTraversal() {
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "../../etc/passwd")) { error in
            XCTAssertEqual(error as? FileNameError, .pathTraversal)
        }
    }

    func test_validate_rejectsBackslashSeparator() {
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "foo\\bar.gguf")) { error in
            XCTAssertEqual(error as? FileNameError, .backslash)
        }
    }

    func test_validate_rejectsDoubleForwardSlash() {
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "foo//bar.gguf")) { error in
            // "foo//bar.gguf" splits to ["foo", "", "bar.gguf"] — tooManyComponents fires first.
            XCTAssertEqual(error as? FileNameError, .tooManyComponents)
        }
    }

    func test_validate_rejectsDoubleForwardSlashInTwoComponentShape() {
        // "foo//" has only two segments after split: ["foo", "", ""]? Actually three.
        // Need a case where tooManyComponents doesn't trigger but emptyComponent does.
        // That means exactly two segments with one empty: "/foo" or "foo/".
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "foo/")) { error in
            XCTAssertEqual(error as? FileNameError, .emptyComponent)
        }
    }

    func test_validate_rejectsMultiComponentPath() {
        // Deeper sub-paths are not a HuggingFace filename pattern we honour.
        XCTAssertThrowsError(
            try DownloadableModel.validate(fileName: "user/repo/subdir/file.gguf")
        ) { error in
            XCTAssertEqual(error as? FileNameError, .tooManyComponents)
        }
    }

    func test_validate_rejectsLeadingDot() {
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: ".hidden")) { error in
            XCTAssertEqual(error as? FileNameError, .hidden)
        }
    }

    func test_validate_rejectsLeadingDotOnIntermediateComponent() {
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "safe/.hidden")) { error in
            XCTAssertEqual(error as? FileNameError, .hidden)
        }
    }

    func test_validate_rejectsNullByte() {
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "model\0.gguf")) { error in
            XCTAssertEqual(error as? FileNameError, .controlCharacter)
        }
    }

    func test_validate_rejectsControlCharacter() {
        // Newline (0x0A) is a control character.
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "model\n.gguf")) { error in
            XCTAssertEqual(error as? FileNameError, .controlCharacter)
        }
    }

    func test_validate_rejectsDelCharacter() {
        // DEL (0x7F) is outside the printable range.
        let name = "model\u{007F}.gguf"
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: name)) { error in
            XCTAssertEqual(error as? FileNameError, .controlCharacter)
        }
    }

    func test_validate_rejectsOverlyLongName() {
        let longName = String(repeating: "a", count: 300) + ".gguf"
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: longName)) { error in
            XCTAssertEqual(error as? FileNameError, .tooLong)
        }
    }

    func test_validate_rejectsSingleDotComponent() {
        // "./model.gguf" collapses to "model.gguf" after standardization but
        // should be rejected at validation time.
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "./model.gguf")) { error in
            XCTAssertEqual(error as? FileNameError, .pathTraversal)
        }
    }

    func test_validate_rejectsTrailingSlash() {
        // Remove duplication with test_validate_rejectsDoubleForwardSlashInTwoComponentShape:
        // keep the classical trailing-slash assertion distinct and explicit.
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "repo/")) { error in
            XCTAssertEqual(error as? FileNameError, .emptyComponent)
        }
    }

    func test_validate_rejectsLeadingSlash() {
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "/foo.gguf")) { error in
            XCTAssertEqual(error as? FileNameError, .emptyComponent)
        }
    }

    // MARK: - Error-description UX
    //
    // Host apps surface `localizedDescription` in banners / Xcode console. These
    // assertions lock the copy so a new rejection rule cannot regress to an
    // opaque message like "invalid path separator" with no indication of which
    // sub-rule tripped.

    func test_validate_errorDescriptions_areDistinctPerCase() {
        let descriptions: [String?] = [
            FileNameError.empty.errorDescription,
            FileNameError.pathTraversal.errorDescription,
            FileNameError.backslash.errorDescription,
            FileNameError.emptyComponent.errorDescription,
            FileNameError.tooManyComponents.errorDescription,
            FileNameError.hidden.errorDescription,
            FileNameError.tooLong.errorDescription,
            FileNameError.controlCharacter.errorDescription,
        ]
        let unique = Set(descriptions.compactMap { $0 })
        XCTAssertEqual(
            unique.count, descriptions.count,
            "Each FileNameError case must have a distinct localizedDescription"
        )
    }

    // MARK: - Unicode Fuzz

    func test_validate_acceptsNonASCIIButPrintableName() {
        // Emoji and combining marks above U+001F should not themselves fail the
        // control-character check. APFS will accept them and the URL prefix
        // guard elsewhere handles escaping. (No filesystem actually *wants*
        // these in filenames, but the validator's contract is path-safety, not
        // aesthetics.)
        XCTAssertNoThrow(try DownloadableModel.validate(fileName: "modèle-\u{1F600}.gguf"))
        XCTAssertNoThrow(try DownloadableModel.validate(fileName: "café.gguf"))
        // Non-ASCII digit: ARABIC-INDIC DIGIT FOUR (U+0664) is not a traversal token.
        XCTAssertNoThrow(try DownloadableModel.validate(fileName: "model-\u{0664}.gguf"))
    }

    func test_validate_rejectsZeroWidthControlsInMixedScript() {
        // U+0007 BELL: C0 control, inside a mixed-script filename.
        let payload = "mödèl\u{0007}-Q4.gguf"
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: payload)) { error in
            XCTAssertEqual(error as? FileNameError, .controlCharacter)
        }
    }

    func test_validate_rejectsUnicodeLineSeparatorsAsControls() {
        // U+0085 NEXT LINE is in the C1 control range (0x80–0x9F) which the
        // validator rejects even though it renders invisibly.
        let payload = "model\u{0085}.gguf"
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: payload)) { error in
            XCTAssertEqual(error as? FileNameError, .controlCharacter)
        }
    }

    func test_validate_rejectsUnicodeTabInAnyComponent() {
        // U+0009 TAB — C0 control, occasionally survives clipboard round-trips.
        XCTAssertThrowsError(try DownloadableModel.validate(fileName: "mlx-community/Phi\t-4")) { error in
            XCTAssertEqual(error as? FileNameError, .controlCharacter)
        }
    }
}
