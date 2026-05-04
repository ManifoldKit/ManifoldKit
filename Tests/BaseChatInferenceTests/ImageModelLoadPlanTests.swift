import XCTest
@testable import BaseChatInference

/// Coverage for `ImageModelLoadPlan.compute(inputs:)`.
///
/// Mirrors `ModelLoadPlanTests` in spirit: each test fixes one dimension of
/// the diffusion budget (UNet alone, total-but-not-individual, activation
/// memory, comfortable fit) and asserts the resulting verdict + the specific
/// reason cases that should appear.
final class ImageModelLoadPlanTests: XCTestCase {

    private let oneGB: Int64 = 1_073_741_824

    // MARK: - Helpers

    private func inputs(
        unet: Int64,
        vae: Int64,
        textEncoder: Int64,
        activation: Int64,
        available: Int64,
        width: Int = 1024,
        height: Int = 1024
    ) -> ImageModelLoadPlan.Inputs {
        ImageModelLoadPlan.Inputs(
            unetWeightBytes: unet,
            vaeWeightBytes: vae,
            textEncoderWeightBytes: textEncoder,
            activationMemoryBytes: activation,
            availableMemoryBytes: available,
            targetWidth: width,
            targetHeight: height
        )
    }

    // MARK: - 1. Comfortable headroom

    func test_comfortableHeadroom_returnsAllow() {
        // 4 GB total against 16 GB available → well under 85 % threshold.
        let plan = ImageModelLoadPlan.compute(inputs: inputs(
            unet: 2 * oneGB,
            vae: oneGB / 4,
            textEncoder: oneGB / 2,
            activation: oneGB,
            available: 16 * oneGB
        ))

        XCTAssertEqual(plan.verdict, .allow)
        XCTAssertTrue(plan.reasons.isEmpty)
        XCTAssertGreaterThan(plan.headroomBytes, 0)
    }

    // MARK: - 2. UNet alone exceeds budget → blocked, reason names UNet

    func test_unetExceedsBudget_returnsDenyWithUnetReason() {
        // UNet alone is bigger than the entire device budget.
        let plan = ImageModelLoadPlan.compute(inputs: inputs(
            unet: 8 * oneGB,
            vae: oneGB / 4,
            textEncoder: oneGB / 2,
            activation: oneGB,
            available: 4 * oneGB
        ))

        XCTAssertEqual(plan.verdict, .deny)
        XCTAssertTrue(
            plan.reasons.contains { reason in
                if case .unetTooLarge = reason { return true }
                return false
            },
            "expected .unetTooLarge in reasons; got \(plan.reasons)"
        )
        // No aggregate reason should be reported when a single dimension
        // already explains the failure.
        XCTAssertFalse(
            plan.reasons.contains { reason in
                if case .totalExceedsBudget = reason { return true }
                return false
            }
        )
    }

    // MARK: - 3. Total exceeds budget though no single dimension does

    func test_totalExceedsBudget_returnsDenyWithAggregateReason() {
        // Each individual piece comfortably fits in 4 GB, but their sum is 6 GB.
        let plan = ImageModelLoadPlan.compute(inputs: inputs(
            unet: 2 * oneGB,
            vae: oneGB,
            textEncoder: oneGB,
            activation: 2 * oneGB,
            available: 4 * oneGB
        ))

        XCTAssertEqual(plan.verdict, .deny)
        XCTAssertTrue(
            plan.reasons.contains { reason in
                if case .totalExceedsBudget = reason { return true }
                return false
            },
            "expected .totalExceedsBudget aggregate reason; got \(plan.reasons)"
        )
        // Sanity: no single-dimension reason should appear here.
        for reason in plan.reasons {
            switch reason {
            case .unetTooLarge, .vaeTooLarge, .textEncoderTooLarge, .activationMemoryExceedsBudget:
                XCTFail("unexpected single-dimension reason \(reason) when total-only exceeded")
            case .totalExceedsBudget:
                break
            }
        }
    }

    // MARK: - 4. Activation memory dominates

    func test_activationMemoryDominates_returnsDenyWithActivationReason() {
        // Tiny weights, huge activation working set (e.g. 4K render on a 4 GB iPad).
        let plan = ImageModelLoadPlan.compute(inputs: inputs(
            unet: oneGB / 4,
            vae: oneGB / 8,
            textEncoder: oneGB / 8,
            activation: 8 * oneGB,
            available: 4 * oneGB,
            width: 4096,
            height: 4096
        ))

        XCTAssertEqual(plan.verdict, .deny)
        XCTAssertTrue(
            plan.reasons.contains { reason in
                if case .activationMemoryExceedsBudget = reason { return true }
                return false
            },
            "expected .activationMemoryExceedsBudget; got \(plan.reasons)"
        )
    }

    // MARK: - 5. Headroom math correctness

    func test_headroomMath_comfortableCase() {
        let inputsValue = inputs(
            unet: 2 * oneGB,
            vae: oneGB / 4,
            textEncoder: oneGB / 2,
            activation: oneGB,
            available: 16 * oneGB
        )
        let plan = ImageModelLoadPlan.compute(inputs: inputsValue)

        let expectedTotal = inputsValue.unetWeightBytes
            + inputsValue.vaeWeightBytes
            + inputsValue.textEncoderWeightBytes
            + inputsValue.activationMemoryBytes
        XCTAssertEqual(plan.totalEstimatedBytes, expectedTotal)
        XCTAssertEqual(plan.headroomBytes, inputsValue.availableMemoryBytes - expectedTotal)
        XCTAssertGreaterThan(plan.headroomBytes, 0)
    }

    func test_headroomMath_blockedCaseHasNegativeHeadroom() {
        let inputsValue = inputs(
            unet: 8 * oneGB,
            vae: oneGB,
            textEncoder: oneGB,
            activation: 2 * oneGB,
            available: 4 * oneGB
        )
        let plan = ImageModelLoadPlan.compute(inputs: inputsValue)

        let expectedTotal = inputsValue.unetWeightBytes
            + inputsValue.vaeWeightBytes
            + inputsValue.textEncoderWeightBytes
            + inputsValue.activationMemoryBytes
        XCTAssertEqual(plan.totalEstimatedBytes, expectedTotal)
        XCTAssertEqual(plan.headroomBytes, inputsValue.availableMemoryBytes - expectedTotal)
        XCTAssertLessThan(plan.headroomBytes, 0)
    }

    // MARK: - 6. Equatable

    func test_inputsEquatable_identicalInputsAreEqual() {
        let a = inputs(
            unet: oneGB,
            vae: oneGB / 4,
            textEncoder: oneGB / 2,
            activation: oneGB,
            available: 8 * oneGB
        )
        let b = inputs(
            unet: oneGB,
            vae: oneGB / 4,
            textEncoder: oneGB / 2,
            activation: oneGB,
            available: 8 * oneGB
        )
        XCTAssertEqual(a, b)

        let planA = ImageModelLoadPlan.compute(inputs: a)
        let planB = ImageModelLoadPlan.compute(inputs: b)
        XCTAssertEqual(planA.outcome, planB.outcome)
    }

    func test_outcomeEquatable_differentInputsProduceDifferentOutcomes() {
        let allowPlan = ImageModelLoadPlan.compute(inputs: inputs(
            unet: oneGB,
            vae: oneGB / 4,
            textEncoder: oneGB / 2,
            activation: oneGB,
            available: 16 * oneGB
        ))
        let denyPlan = ImageModelLoadPlan.compute(inputs: inputs(
            unet: 8 * oneGB,
            vae: oneGB,
            textEncoder: oneGB,
            activation: 2 * oneGB,
            available: 4 * oneGB
        ))
        XCTAssertNotEqual(allowPlan.outcome, denyPlan.outcome)
    }

    // MARK: - Verdict thresholds

    func test_warnVerdict_atTightFit() {
        // Total is between 85 % and 100 % of available → warn.
        // 16 GB available; aim for ~95 % = 15.2 GB.
        let plan = ImageModelLoadPlan.compute(inputs: inputs(
            unet: 12 * oneGB,
            vae: oneGB / 4,
            textEncoder: oneGB / 2,
            activation: 2 * oneGB + oneGB / 2,
            available: 16 * oneGB
        ))
        XCTAssertEqual(plan.verdict, .warn)
        // No reasons on warn — reasons are blocked-only diagnostic.
        XCTAssertTrue(plan.reasons.isEmpty)
    }
}
