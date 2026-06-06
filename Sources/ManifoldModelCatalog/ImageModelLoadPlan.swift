import Foundation
import ManifoldHardware

/// Pre-load memory budget decision for an image-generation model.
///
/// Sibling to ``ModelLoadPlan`` for text inference: same shape (an `Inputs`
/// value carrying everything the decision depends on, an `Outcome` carrying
/// the verdict + estimates + reasons), but with diffusion-shaped fields. A
/// diffusion stack at load time has a fundamentally different memory profile
/// than an autoregressive LM — there is no KV cache to size, and no trained
/// context length to clamp against. What dominates instead is the sum of
/// **UNet weights**, **VAE weights**, **text-encoder weights** (one or two,
/// depending on the architecture — SDXL has both CLIP-G and CLIP-L), and
/// **activation memory at the target resolution** (which scales roughly with
/// `width × height` for the UNet's intermediate tensors).
///
/// ## Vocabulary sharing with `ModelLoadPlan`
///
/// The umbrella issue (#1002) calls for sharing `Verdict` / `Reason`
/// vocabulary "where the vocabulary is genuinely shared." Here we reuse
/// ``ModelLoadPlan/Verdict`` directly — `.allow` / `.warn` / `.deny` is
/// genuinely generic decision vocabulary that says nothing text-specific.
/// `Reason`, by contrast, is text-shaped on the original side
/// (`insufficientKVCache`, `trainedContextExceeded`, etc.), so this type
/// defines its own parallel ``Reason`` with diffusion-specific cases. The
/// names mirror the text-side spirit (`insufficientResident` → `unetTooLarge`,
/// `insufficientKVCache` → `activationMemoryExceedsBudget`) so a reader who
/// knows the text path can navigate the image path by analogy.
///
/// ## Activation memory note
///
/// `Inputs.activationMemoryBytes` is the **caller's** estimate of the working
/// set the UNet needs in addition to its weights at the target resolution.
/// Concrete backends (PR 6+) compute this from architecture-specific formulas
/// (UNet channel counts × spatial dimensions × precision). This type does not
/// estimate it on the caller's behalf — it just budgets against it.
public struct ImageModelLoadPlan: Sendable {

    /// The raw inputs a plan was computed from. Captured on the plan so callers
    /// can log, diff, or re-evaluate with different parameters without
    /// re-querying state.
    public struct Inputs: Sendable, Equatable {
        /// Bytes occupied by the UNet weights file(s) on disk. The UNet
        /// dominates the memory profile of every diffusion architecture this
        /// crate currently targets.
        public let unetWeightBytes: Int64

        /// Bytes occupied by the VAE weights file(s) on disk. Used by both the
        /// encode (image-to-latent, for img2img) and decode (latent-to-image,
        /// always) paths.
        public let vaeWeightBytes: Int64

        /// Total bytes occupied by all text-encoder weight files. SDXL has
        /// two encoders (CLIP-G + CLIP-L), SD 1.5 / FLUX-Schnell have one.
        /// Callers sum across encoders before constructing the inputs.
        public let textEncoderWeightBytes: Int64

        /// Estimated activation working set the UNet allocates at the target
        /// resolution, on top of its weights. Scales roughly with
        /// `width × height`. The caller (typically the backend conformer)
        /// owns this estimate; we only budget against it.
        public let activationMemoryBytes: Int64

        /// Device memory budget the load is being checked against, after any
        /// OS / app-overhead reserves the caller chose to apply. This is the
        /// same shape as ``ModelLoadPlan/Inputs/availableMemoryBytes`` but
        /// stored as `Int64` to match the rest of the diffusion-shaped fields
        /// (caller-supplied byte counts) — saturating arithmetic in
        /// ``compute(inputs:)`` keeps negative headroom expressible without
        /// `UInt64` underflow.
        public let availableMemoryBytes: Int64

        /// Target output width in pixels. Carried on the plan so logs / UI
        /// can show the resolution the budget was evaluated at; not used by
        /// the math directly (the activation estimate is already a function
        /// of resolution).
        public let targetWidth: Int

        /// Target output height in pixels. See ``targetWidth``.
        public let targetHeight: Int

        public init(
            unetWeightBytes: Int64,
            vaeWeightBytes: Int64,
            textEncoderWeightBytes: Int64,
            activationMemoryBytes: Int64,
            availableMemoryBytes: Int64,
            targetWidth: Int,
            targetHeight: Int
        ) {
            self.unetWeightBytes = unetWeightBytes
            self.vaeWeightBytes = vaeWeightBytes
            self.textEncoderWeightBytes = textEncoderWeightBytes
            self.activationMemoryBytes = activationMemoryBytes
            self.availableMemoryBytes = availableMemoryBytes
            self.targetWidth = targetWidth
            self.targetHeight = targetHeight
        }
    }

    /// Decision produced from an ``Inputs``. Decoupled so UI code can show the
    /// summary without re-carrying every input field.
    public struct Outcome: Sendable, Equatable {
        /// Sum of all weight + activation bytes — what the load is expected to
        /// consume in total.
        public let totalEstimatedBytes: Int64

        /// `availableMemoryBytes - totalEstimatedBytes`. Negative when the
        /// budget would be exceeded.
        public let headroomBytes: Int64

        /// Reuses ``ModelLoadPlan/Verdict`` — `.allow` / `.warn` / `.deny`
        /// are generic decision vocabulary.
        public let verdict: ModelLoadPlan.Verdict

        /// Diffusion-specific reasons the verdict was reached. Empty on a
        /// comfortable `.allow`. Multiple reasons can co-occur — e.g. a
        /// blocked plan where both UNet alone and total exceed the budget
        /// will list both.
        public let reasons: [Reason]

        public init(
            totalEstimatedBytes: Int64,
            headroomBytes: Int64,
            verdict: ModelLoadPlan.Verdict,
            reasons: [Reason]
        ) {
            self.totalEstimatedBytes = totalEstimatedBytes
            self.headroomBytes = headroomBytes
            self.verdict = verdict
            self.reasons = reasons
        }
    }

    public let inputs: Inputs
    public let outcome: Outcome

    public init(inputs: Inputs, outcome: Outcome) {
        self.inputs = inputs
        self.outcome = outcome
    }

    // MARK: - Convenience pass-throughs

    public var verdict: ModelLoadPlan.Verdict { outcome.verdict }
    public var reasons: [Reason] { outcome.reasons }
    public var totalEstimatedBytes: Int64 { outcome.totalEstimatedBytes }
    public var headroomBytes: Int64 { outcome.headroomBytes }

    // MARK: - Reason

    /// Diffusion-shaped reason vocabulary. Parallel to ``ModelLoadPlan/Reason``
    /// but with cases that point at the dimension(s) of the diffusion stack
    /// that pushed past the budget — text-side reasons (KV cache, trained
    /// context length) have no analog here.
    public enum Reason: Sendable, Equatable {
        /// UNet weights alone exceed the available budget. Reported even if
        /// other dimensions also exceed — surfacing this lets the caller
        /// suggest a smaller variant (e.g. SDXL → SD 1.5).
        case unetTooLarge(required: Int64, available: Int64)

        /// VAE weights alone exceed the available budget. Rare in practice
        /// (VAEs are small), but reported when it happens for diagnostic
        /// completeness.
        case vaeTooLarge(required: Int64, available: Int64)

        /// Text-encoder weights alone exceed the available budget. SDXL's
        /// dual CLIP encoders can push this case on memory-constrained
        /// devices.
        case textEncoderTooLarge(required: Int64, available: Int64)

        /// Activation memory at the target resolution exceeds the available
        /// budget. The caller can mitigate by lowering ``Inputs/targetWidth``
        /// / ``Inputs/targetHeight``.
        case activationMemoryExceedsBudget(required: Int64, available: Int64)

        /// Aggregate budget exceeded even though no single dimension does.
        /// The classic "everything fits individually but not together" case.
        case totalExceedsBudget(required: Int64, available: Int64)
    }

    // MARK: - Computation

    /// Primary entry point. All state must be pre-materialised on ``Inputs``.
    ///
    /// Verdict thresholds mirror ``ModelLoadPlan/compute(inputs:)``:
    /// - ≤ 85 % of available → `.allow`
    /// - ≤ 100 % of available → `.warn`
    /// - > 100 % of available → `.deny`
    ///
    /// On `.deny`, every dimension that individually exceeds the budget is
    /// recorded as a reason, and ``Reason/totalExceedsBudget(required:available:)``
    /// is appended when no single dimension exceeded but the sum did.
    public static func compute(inputs: Inputs) -> ImageModelLoadPlan {
        let total: Int64 = inputs.unetWeightBytes
            &+ inputs.vaeWeightBytes
            &+ inputs.textEncoderWeightBytes
            &+ inputs.activationMemoryBytes
        let headroom: Int64 = inputs.availableMemoryBytes &- total
        let available = inputs.availableMemoryBytes

        let allowThreshold: Int64 = Int64(Double(available) * 0.85)

        let verdict: ModelLoadPlan.Verdict
        var reasons: [Reason] = []

        if total <= allowThreshold {
            verdict = .allow
        } else if total <= available {
            verdict = .warn
        } else {
            verdict = .deny

            // Surface every dimension that individually exceeded the budget so
            // the caller can narrow on the actual offender(s) rather than the
            // aggregate.
            var anySingleDimensionExceeded = false
            if inputs.unetWeightBytes > available {
                reasons.append(.unetTooLarge(
                    required: inputs.unetWeightBytes,
                    available: available
                ))
                anySingleDimensionExceeded = true
            }
            if inputs.vaeWeightBytes > available {
                reasons.append(.vaeTooLarge(
                    required: inputs.vaeWeightBytes,
                    available: available
                ))
                anySingleDimensionExceeded = true
            }
            if inputs.textEncoderWeightBytes > available {
                reasons.append(.textEncoderTooLarge(
                    required: inputs.textEncoderWeightBytes,
                    available: available
                ))
                anySingleDimensionExceeded = true
            }
            if inputs.activationMemoryBytes > available {
                reasons.append(.activationMemoryExceedsBudget(
                    required: inputs.activationMemoryBytes,
                    available: available
                ))
                anySingleDimensionExceeded = true
            }

            // Always record the aggregate when no single dimension was the
            // culprit — this is the "death by a thousand cuts" case where
            // each piece fits but they don't fit together.
            if !anySingleDimensionExceeded {
                reasons.append(.totalExceedsBudget(
                    required: total,
                    available: available
                ))
            }
        }

        let outcome = Outcome(
            totalEstimatedBytes: total,
            headroomBytes: headroom,
            verdict: verdict,
            reasons: reasons
        )
        return ImageModelLoadPlan(inputs: inputs, outcome: outcome)
    }
}
